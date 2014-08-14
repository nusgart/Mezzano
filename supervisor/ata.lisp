(in-package :mezzanine.supervisor)

(defconstant +ata-compat-primary-command+ #x1F0)
(defconstant +ata-compat-primary-control+ #x3F0)
(defconstant +ata-compat-primary-irq+ 14)
(defconstant +ata-compat-secondary-command+ #x170)
(defconstant +ata-compat-secondary-control+ #x370)
(defconstant +ata-compat-secondary-irq+ 15)

(defconstant +ata-register-data+ 0) ; read/write
(defconstant +ata-register-error+ 1) ; read
(defconstant +ata-register-features+ 1) ; write
(defconstant +ata-register-count+ 2) ; read/write
(defconstant +ata-register-lba-low+ 3) ; read/write
(defconstant +ata-register-lba-mid+ 4) ; read/write
(defconstant +ata-register-lba-high+ 5) ; read/write
(defconstant +ata-register-device+ 6) ; read/write
(defconstant +ata-register-status+ 7) ; read
(defconstant +ata-register-command+ 7) ; write

(defconstant +ata-register-alt-status+ 6) ; read
(defconstant +ata-register-device-control+ 6) ; write

;; Device bits.
(defconstant +ata-dev+  #x10 "Select device 0 when clear, device 1 when set.")
(defconstant +ata-lba+  #x40 "Set when using LBA.")

;; Status bits.
(defconstant +ata-err+  #x01 "An error occured during command execution.")
(defconstant +ata-drq+  #x08 "Device is ready to transfer data.")
(defconstant +ata-df+   #x20 "Device fault.")
(defconstant +ata-drdy+ #x40 "Device is ready to accept commands.")
(defconstant +ata-bsy+  #x80 "Device is busy.")

;; Device Control bits.
(defconstant +ata-nien+ #x02 "Mask interrupts.")
(defconstant +ata-srst+ #x04 "Initiate a software reset.")
(defconstant +ata-hob+  #x80 "Read LBA48 high-order bytes.")

;; Commands.
(defconstant +ata-command-read-sectors+ #x20)
(defconstant +ata-command-write-sectors+ #x30)
(defconstant +ata-command-identify+ #xEC)

(defvar *ata-devices*)

(defstruct (ata-controller
             (:area :wired))
  ;; Taken when accessing the controller.
  (access-lock (make-mutex "ATA Access Lock" :spin))
  ;; Taken while there's a command in progress.
  (command-lock (make-mutex "ATA Command Lock"))
  command
  control
  irq
  current-channel
  (irq-cvar (make-condition-variable "ATA IRQ Notifier")))

(defstruct (ata-device
             (:area :wired))
  controller
  channel
  block-size
  sector-count)

(defun ata-alt-status (controller)
  "Read the alternate status register."
  (sys.int::io-port/8 (+ (ata-controller-control controller)
                         +ata-register-alt-status+)))

(defun ata-wait-for-controller (controller mask value timeout)
  "Wait for the bits in the alt-status register masked by MASK to become equal to VALUE.
Returns true when the bits are equal, false when the timeout expires or if the device sets ERR."
  (loop
     (let ((status (ata-alt-status controller)))
       (when (logtest status +ata-err+)
         (return nil))
       (when (eql (logand status mask) value)
         (return t)))
     (when (<= timeout 0)
       (return nil))
     (sleep 0.001)
     (decf timeout 0.001)))

(defun ata-select-device (controller channel)
  ;; select-device should never be called with a command in progress on the controller.
  (when (logtest (logior +ata-bsy+ +ata-drq+)
                 (ata-alt-status controller))
    (debug-write-line "ATA-SELECT-DEVICE called with command in progress.")
    (return-from ata-select-device nil))
  (when (not (eql (ata-controller-current-channel controller) channel))
    (assert (or (eql channel :master) (eql channel :slave)))
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-device+))
          (ecase channel
            (:master 0)
            (:slave +ata-dev+)))
    ;; Again, neither BSY nor DRQ should be set.
    (when (logtest (logior +ata-bsy+ +ata-drq+)
                   (ata-alt-status controller))
      (debug-write-line "ATA-SELECT-DEVICE called with command in progress.")
      (return-from ata-select-device nil))
    (setf (ata-controller-current-channel controller) channel))
  t)

(defun ata-detect-drive (controller channel)
  (let ((buf (sys.int::make-simple-vector 256)))
    (with-mutex ((ata-controller-access-lock controller))
      ;; Select the device.
      (when (not (ata-select-device controller channel))
        (debug-write-line "Could not select ata device when probing.")
        (return-from ata-detect-drive nil))
      ;; Issue IDENTIFY.
      (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                   +ata-register-command+))
            +ata-command-identify+)
      ;; Delay 400ns after writing command.
      (ata-alt-status controller)
      ;; Wait for BSY to clear and DRQ to go high.
      ;; Use a 1 second timeout.
      ;; I don't know if there's a standard timeout for this, but
      ;; I figure that the device should respond to IDENTIFY quickly.
      ;; Wrong blah! ata-wait-for-controller is nonsense.
      ;; if bsy = 0 & drq = 0, then there was an error.
      (let ((success (ata-wait-for-controller controller (logior +ata-bsy+ +ata-drq+) +ata-drq+ 1)))
        ;; Check ERR before checking for timeout.
        ;; ATAPI devices will abort, and wait-for-controller will time out.
        (when (logtest (ata-alt-status controller) +ata-err+)
          (debug-write-line "IDENTIFY aborted by device.")
          (return-from ata-detect-drive))
        (when (not success)
          (debug-write-line "Timeout while waiting for DRQ during IDENTIFY.")
          (return-from ata-detect-drive)))
      ;; Read data.
      (dotimes (i 256)
        ;; IDENTIFY data from the drive is big-endian, byteswap.
        (let ((data (sys.int::io-port/16 (+ (ata-controller-command controller)
                                            +ata-register-data+))))
          (setf (svref buf i) (logior (ash (logand data #xFF) 8)
                                      (ash data -8))))))
    (setf *ata-devices*
          (sys.int::cons-in-area
           (make-ata-device :controller controller
                            :channel channel
                            ;; Check for large sector drives.
                            :block-size (if (and (logbitp 14 (svref buf 106))
                                                 (not (logbitp 13 (svref buf 106))))
                                            (logior (ash (svref buf 117) 16)
                                                    (svref buf 118))
                                            512)
                            ;; TODO: LBA48 support.
                            :sector-count (logior (ash (svref buf 60) 16)
                                                  (svref buf 61)))
           *ata-devices*
           :wired))))

(defun ata-issue-lba28-command (device lba count command)
  (let ((controller (ata-device-controller device)))
    ;; Select the device.
    (when (not (ata-select-device controller (ata-device-channel device)))
      (debug-write-line "Could not select ata device.")
      (return-from ata-issue-lba28-command nil))
    ;; HI3: Write_parameters
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-count+))
          (if (eql count 256)
              0
              count))
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-lba-low+))
          (ldb (byte 8 0) lba))
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-lba-mid+))
          (ldb (byte 8 8) lba))
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-lba-high+))
          (ldb (byte 8 16) lba))
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-device+))
          (logior (ecase (ata-device-channel device)
                    (:master 0)
                    (:slave +ata-dev+))
                  +ata-lba+
                  (ldb (byte 4 24) lba)))
    ;; HI4: Write_command
    (setf (sys.int::io-port/8 (+ (ata-controller-command controller)
                                 +ata-register-command+))
          command))
  t)

(defun ata-check-status (device &optional (timeout 30))
  "Wait until BSY clears, then return two values.
First is true if DRQ is set, false if DRQ is clear or timeout.
Second is true if the timeout expired.
This is used to implement the Check_Status states of the various command protocols."
  (let ((controller (ata-device-controller device)))
    ;; Sample the alt-status register for the required delay.
    (ata-alt-status controller)
    (loop
       (let ((status (ata-alt-status controller)))
         (when (not (logtest status +ata-bsy+))
           (return (values (logtest status +ata-drq+)
                           nil)))
         ;; Stay in Check_Status.
         (when (<= timeout 0)
           (return (values nil t)))
         (sleep 0.001)
         (decf timeout 0.001)))))

(defun ata-intrq-wait (device &optional (timeout 30))
  "Wait for a interrupt from the device.
This is used to implement the INTRQ_Wait state."
  (declare (ignore timeout))
  ;; FIXME: Timeouts.
  (let ((controller (ata-device-controller device)))
    (condition-wait (ata-controller-irq-cvar controller)
                    (ata-controller-access-lock controller))))

(defun ata-pio-data-in (device count mem-addr)
  "Implement the PIO data-in protocol."
  (let ((controller (ata-device-controller device)))
    (loop
       ;; HPIOI0: INTRQ_wait
       (ata-intrq-wait device)
       ;; HPIOI1: Check_Status
       (multiple-value-bind (drq timed-out)
           (ata-check-status device)
         (when timed-out
           ;; FIXME: Should reset the device here.
           (debug-write-line "Device timeout during PIO data in.")
           (return-from ata-pio-data-in nil))
         (when (not drq)
           ;; FIXME: Should reset the device here.
           (debug-write-line "Device error during PIO data in.")
           (return-from ata-pio-data-in nil)))
       ;; HPIOI2: Transfer_Data
       (dotimes (i 256) ; FIXME: non-512 byte sectors, non 2-byte words.
         (setf (sys.int::memref-unsigned-byte-16 mem-addr 0)
               (sys.int::io-port/16 (+ (ata-controller-command controller)
                                       +ata-register-data+)))
         (incf mem-addr 2))
       ;; If there are no more blocks to transfer, transition back to host idle,
       ;; otherwise return to HPIOI0.
       (when (zerop (decf count))
         (return t)))))

(defun ata-pio-data-out (device count mem-addr)
  "Implement the PIO data-out protocol."
  (let ((controller (ata-device-controller device)))
    (loop
       ;; HPIOO0: Check_Status
       (multiple-value-bind (drq timed-out)
           (ata-check-status device)
         (when timed-out
           ;; FIXME: Should reset the device here.
           (debug-write-line "Device timeout during PIO data out.")
           (return-from ata-pio-data-out nil))
         (when (not drq)
           (cond ((zerop count)
                  ;; All data transfered successfully.
                  (return-from ata-pio-data-out t))
                 (t ;; Error?
                  ;; FIXME: Should reset the device here.
                  (debug-write-line "Device error during PIO data out.")
                  (return-from ata-pio-data-out nil)))))
       ;; HPIOO1: Transfer_Data
       (dotimes (i 256) ; FIXME: non-512 byte sectors, non 2-byte words.
         (setf (sys.int::io-port/16 (+ (ata-controller-command controller)
                                       +ata-register-data+))
               (sys.int::memref-unsigned-byte-16 mem-addr 0))
         (incf mem-addr 2))
       ;; HPIOO2: INTRQ_Wait
       (ata-intrq-wait device)
       ;; Return to HPIOO0.
       (decf count))))

(defun ata-read (device lba count mem-addr)
  (let ((controller (ata-device-controller device)))
    (assert (>= lba 0))
    (assert (>= count 0))
    (assert (< (+ lba count) (ata-device-sector-count device)))
    (when (> count 256)
      (debug-write-line "Can't do reads of more than 256 sectors.")
      (return-from ata-read nil))
    (when (eql count 0)
      (return-from ata-read t))
    (with-mutex ((ata-controller-use-lock controller))
      (with-mutex ((ata-controller-access-lock controller))
        (when (not (ata-issue-lba28-command device lba count +ata-command-read-sectors+))
          (return-from ata-read nil))
        (when (not (ata-pio-data-in device count mem-addr))
          (return-from ata-read nil)))))
  t)

(defun ata-write (device lba count mem-addr)
  (let ((controller (ata-device-controller device)))
    (assert (>= lba 0))
    (assert (>= count 0))
    (assert (< (+ lba count) (ata-device-sector-count device)))
    (when (> count 256)
      (debug-write-line "Can't do writes of more than 256 sectors.")
      (return-from ata-write nil))
    (when (eql count 0)
      (return-from ata-write t))
    (with-mutex ((ata-controller-use-lock controller))
      (with-mutex ((ata-controller-access-lock controller))
        (when (not (ata-issue-lba28-command device lba count +ata-command-write-sectors+))
          (return-from ata-write nil))
        (when (not (ata-pio-data-out device count mem-addr))
          (return-from ata-write nil)))))
  t)

(defun ata-irq-handler (irq)
  (dolist (drive *ata-devices*)
    (when (eql (ata-controller-irq (ata-device-controller drive)) irq)
      (with-mutex ((ata-controller-access-lock controller))
        ;; Read the status register to clear the interrupt pending state.
        (sys.int::io-port/8 (+ (ata-controller-command (ata-device-controller drive))
                               +ata-register-status+))
        (condition-notify (ata-controller-irq-cvar controller))))))

(defun init-ata-controller (command-base control-base irq)
  (let ((controller (make-ata-controller :command command-base
                                         :control control-base
                                         :irq irq)))
    ;; Disable IRQs on the controller and reset both drives.
    (setf (sys.int::io-port/8 (+ control-base +ata-register-device-control+))
          (logior +ata-srst+ +ata-nien+))
    (sleep 0.000005) ; Hold SRST high for 5μs.
    (setf (sys.int::io-port/8 (+ control-base +ata-register-device-control+))
          +ata-nien+)
    (sleep 0.002) ; Hold SRST low for 2ms before probing for drives.
    ;; Now wait for BSY to clear. It may take up to 31 seconds for the
    ;; reset to finish, which is a bit silly...
    (when (not (ata-wait-for-controller controller +ata-bsy+ 0 31))
      ;; BSY did not go low, no devices on this controller.
      (debug-write-line "No devices on ata controller.")
      (return-from init-ata-controller))
    (debug-write-line "Probing ata controller.")
    (i8259-hook-irq irq 'ata-irq-handler) ; fixme: should clear pending irqs?
    (i8259-unmask-irq irq)
    (ata-detect-drive controller :master)
    (ata-detect-drive controller :slave)
    ;; Enable controller interrupts.
    (setf (sys.int::io-port/8 (+ control-base +ata-register-device-control+)) 0)))

(defun initialize-ata ()
  (setf *ata-devices* '())
  (init-ata-controller +ata-compat-primary-command+ +ata-compat-primary-control+ +ata-compat-primary-irq+)
  (init-ata-controller +ata-compat-secondary-command+ +ata-compat-secondary-control+ +ata-compat-secondary-irq+))