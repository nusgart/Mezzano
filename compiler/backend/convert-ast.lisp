;;;; Copyright (c) 2017 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;; Convert a lambda in AST form to a backend-lambda.

(in-package :mezzano.compiler.backend.ast-convert)

(defvar *backend-function*)
(defvar *variable-registers*)
(defvar *go-tag-and-block-labels*)
(defvar *dynamic-stack*)

(defun emit (&rest instructions)
  (dolist (i instructions)
    (append-instruction *backend-function* i)))

(defun convert (lambda)
  (codegen-lambda lambda))

(defun codegen-lambda (lambda)
  (let ((*backend-function* (make-instance 'backend-function :ast-lambda lambda))
        (*variable-registers* (make-hash-table))
        (*go-tag-and-block-labels* (make-hash-table))
        (*dynamic-stack* '()))
    (check-lambda-arguments-are-simple lambda)
    (emit-argument-setup-code lambda)
    (let ((value (cg-form (lambda-information-body lambda) :tail)))
      (when value
        (cond ((eql value :multiple)
               (emit (make-instance 'return-multiple-instruction)))
              (t
               (emit (make-instance 'return-instruction :value value))))))
    *backend-function*))

(defun check-lambda-arguments-are-simple (lambda)
    ;; No keyword arguments, no special arguments, no non-nil
    ;; &optional init-forms and no non-local arguments.
    (assert (not (lambda-information-enable-keys lambda)) ()
            "&KEY arguments did not get lowered!")
    (loop
       for arg in (lambda-information-required-args lambda)
       do (assert (and (lexical-variable-p arg)
                       (localp arg))))
    (loop
       for (arg init-form suppliedp) in (lambda-information-optional-args lambda)
       do
         (assert (and (lexical-variable-p arg)
                      (localp arg)))
         (assert (and (quoted-form-p init-form)
                      (eql (ast-value init-form) nil)))
         (assert (or (null suppliedp)
                     (and (lexical-variable-p suppliedp)
                          (localp suppliedp)))))
    (let ((arg (lambda-information-rest-arg lambda)))
      (assert (or (null arg)
                  (and (lexical-variable-p arg)
                       (localp arg)))))
    (let ((arg (lambda-information-fref-arg lambda)))
      (assert (or (null arg)
                  (and (lexical-variable-p arg)
                       (localp arg)))))
    (let ((arg (lambda-information-closure-arg lambda)))
      (assert (or (null arg)
                  (and (lexical-variable-p arg)
                       (localp arg)))))
    (let ((arg (lambda-information-count-arg lambda)))
      (assert (or (null arg)
                  (and (lexical-variable-p arg)
                       (localp arg))))))

(defun emit-argument-setup-code (lambda)
  (let ((fref-reg (make-instance 'virtual-register :name :fref))
        (closure-reg (make-instance 'virtual-register :name :closure))
        (count-reg (make-instance 'virtual-register :name :count))
        (required-regs (loop
                          for i from 0
                          for arg in (lambda-information-required-args lambda)
                          collect (make-instance 'virtual-register :name `(:required ,i))))
        (optional-regs (loop
                          for i from 0
                          for arg in (lambda-information-optional-args lambda)
                          collect (make-instance 'virtual-register :name `(:optional ,i))))
        (rest-reg (if (lambda-information-rest-arg lambda)
                      (make-instance 'virtual-register :name :rest)
                      nil)))
    (emit (make-instance 'argument-setup-instruction
                         :fref fref-reg
                         :closure closure-reg
                         :count count-reg
                         :required required-regs
                         :optional optional-regs
                         :rest rest-reg))
    ;; Bind arguments to registers.
    (flet ((frob-arg (variable register)
             (when variable
               (setf (gethash variable *variable-registers*) register))))
      (frob-arg (lambda-information-fref-arg lambda) fref-reg)
      (frob-arg (lambda-information-closure-arg lambda) closure-reg)
      (frob-arg (lambda-information-count-arg lambda) count-reg)
      (let ((env-arg (lambda-information-environment-arg lambda)))
        (when env-arg
          (let ((env-reg (make-instance 'virtual-register :name :environment)))
            (emit (make-instance 'move-instruction
                                 :destination env-reg
                                 :source closure-reg))
            (when (not (getf (lambda-information-plist lambda) 'sys.c::unwind-protect-cleanup))
              ;; Read environment pointer from closure object.
              (let ((index (make-instance 'virtual-register)))
                (emit (make-instance 'constant-instruction
                                     :destination index
                                     :value 2))
                (emit (make-instance 'object-get-t-instruction
                                     :destination env-reg
                                     :object env-reg
                                     :index index))))
            (frob-arg env-arg env-reg))))
      ;; Required arguments.
      (loop
         for req-arg in (lambda-information-required-args lambda)
         for reg in required-regs
         do (frob-arg req-arg reg))
      ;; Optional arguments.
      (loop
         for (opt-arg init-form suppliedp) in (lambda-information-optional-args lambda)
         for opt-reg in optional-regs
         for i from 0
         do
           (frob-arg opt-arg opt-reg)
           (when suppliedp
             (let ((sup-reg (make-instance 'virtual-register :name `(:suppliedp ,i)))
                   (index (make-instance 'virtual-register)))
               (frob-arg suppliedp sup-reg)
               (emit (make-instance 'constant-instruction
                                    :destination index
                                    :value (+ (length (lambda-information-required-args lambda)) i)))
               (emit (make-instance 'fixnum-<-instruction
                                    :result sup-reg
                                    :lhs index
                                    :rhs count-reg)))))
      ;; &REST argument.
      (let ((rest-arg (lambda-information-rest-arg lambda)))
        (when (and rest-arg
                   ;; Avoid generating code &REST code when the variable isn't used.
                   (not (zerop (lexical-variable-use-count rest-arg))))
          (when (not (lexical-variable-dynamic-extent rest-arg))
            (emit (make-instance 'call-instruction
                                 :result rest-reg
                                 :function 'copy-list
                                 :arguments (list rest-reg))))
          (frob-arg rest-arg rest-reg))))))

(defun unwind-dynamic-stack-to (target)
  (let ((current *dynamic-stack*))
    (loop
       (when (eql current target)
         (return))
       (assert (not (endp current)))
       (let ((entry (pop current)))
         (ecase (first entry)
           (:nlx
            (emit (make-instance 'finish-nlx-instruction
                                 :region (third entry)
                                 :context (second entry))))
           (:saved-mv
            (emit (make-instance 'forget-multiple-instruction
                                 :context (second entry)))))))))

;;; Generate code for an AST node.
;;;
;;; RESULT-MODE must be one of:
;;;   :EFFECT   - form is compiled only for effect, and the result value will be ignored
;;;   :VALUE    - form should produce a single value in a virtual-register
;;;   :MULTIPLE - form should produce a single value or multiple values
;;;   :TAIL     - form should produce a single value, multiple values, or return multiple values.
;;;
;;; Must return one of:
;;;   NIL       - When control terminates inside the form.
;;;   :EFFECT   - When the form does not terminate control and has produced no specific value. Only valid when RESULT-MODE is :EFFECT.
;;;   virtual-register - When the form produces a single value.
;;;   :MULTIPLE - When the form has produced multiple values. Only valid when RESULT-MODE is :MULTIPLE or :TAIL.
(defgeneric cg-form (form result-mode))

(defmethod cg-form ((form ast-block) result-mode)
  (let* ((info (ast-info form))
         (result-reg (make-instance 'virtual-register :name :block-result))
         (escape-reg (make-instance 'virtual-register :name :block-escape))
         (exit-label (make-instance 'label :name :block-exit))
         (thunk-label (make-instance 'label :name :block-thunk))
         (escapes (block-information-env-var info))
         (*dynamic-stack* *dynamic-stack*)
         (nlx-region (make-instance 'begin-nlx-instruction
                                    :context escape-reg
                                    :targets (list thunk-label))))
    (when escapes
      (emit nlx-region)
      (push `(:nlx ,escape-reg ,nlx-region) *dynamic-stack*)
      (setf (gethash info *variable-registers*) escape-reg))
    (setf (gethash info *go-tag-and-block-labels*) exit-label)
    (setf (block-information-return-mode info) (list result-mode result-reg *dynamic-stack*)
          (block-information-count info) 0)
    ;; Generate (return-from block body).
    (cg-form (make-instance 'ast-return-from
                            :inherit form
                            :info info
                            :value (ast-body form)
                            :target info)
             :effect)
    (when (zerop (block-information-count info))
      ;; Nothing reached the exit.
      (return-from cg-form nil))
    (when escapes
      (emit thunk-label)
      (ecase result-mode
        ((:multiple :tail)
         (emit (make-instance 'nlx-entry-multiple-instruction
                              :region nlx-region
                              :context escape-reg)))
        (:value
         (emit (make-instance 'nlx-entry-instruction
                              :region nlx-region
                              :context escape-reg
                              :value result-reg)))
        (:effect
         (emit (make-instance 'nlx-entry-instruction
                              :region nlx-region
                              :context escape-reg
                              :value (make-instance 'virtual-register)))))
      (emit (make-instance 'jump-instruction
                           :target exit-label)))
    (emit exit-label)
    (when escapes
      (emit (make-instance 'finish-nlx-instruction
                           :region nlx-region
                           :context escape-reg)))
    (ecase result-mode
      ((:multiple :tail)
       :multiple)
      (:value
       result-reg)
      (:effect
       :effect))))

(defmethod cg-form ((form ast-return-from) result-mode)
  (let* ((local-info (gethash (ast-target form) *go-tag-and-block-labels*))
         (real-result-mode (first (block-information-return-mode (ast-target form))))
         (result-reg (second (block-information-return-mode (ast-target form))))
         (target-tag (when (not local-info)
                       (cg-form (ast-info form) :value)))
         (value (cg-form (ast-value form)
                         ;; Non-local exits must not use tail calls.
                         (if (and (eql real-result-mode :tail)
                                  (not local-info))
                             :multiple
                             real-result-mode))))
    (when (not value)
      (return-from cg-form nil))
    (incf (block-information-count (ast-target form)))
    (when (and (member real-result-mode '(:multiple :tail))
               (not (eql value :multiple)))
      (emit (make-instance 'values-instruction
                           :values (list value)))
      (setf value :multiple))
    (cond (local-info ; local jump
           (when (eql real-result-mode :value)
             (emit (make-instance 'move-instruction
                                  :destination result-reg
                                  :source value)))
           (unwind-dynamic-stack-to (third (block-information-return-mode (ast-target form))))
           (emit (make-instance 'jump-instruction
                                :target local-info)))
          (t ; non-local exit
           (ecase real-result-mode
             ((:multiple :tail)
              (emit (make-instance 'invoke-nlx-multiple-instruction
                                   :context target-tag
                                   :index 0)))
             (:value
              (emit (make-instance 'invoke-nlx-instruction
                                   :context target-tag
                                   :index 0
                                   :value value)))
             (:effect
              (let ((nil-val (cg-form (make-instance 'ast-quote :value nil) :value)))
                (emit (make-instance 'invoke-nlx-instruction
                                     :context target-tag
                                     :index 0
                                     :value nil-val))))))))
  nil)

(defmethod cg-form ((form ast-function) result-mode)
  (let ((fref-reg (make-instance 'virtual-register))
        (fref-index (make-instance 'virtual-register))
        (fname-reg (make-instance 'virtual-register))
        (is-defined (make-instance 'virtual-register))
        (out (make-instance 'label :name :out))
        (result (make-instance 'virtual-register)))
    (emit (make-instance 'constant-instruction
                         :destination fref-reg
                         :value (sys.int::function-reference (ast-name form))))
    (emit (make-instance 'constant-instruction
                         :destination fref-index
                         :value sys.int::+fref-function+))
    (emit (make-instance 'object-get-t-instruction
                         :destination result
                         :object fref-reg
                         :index fref-index))
    (emit (make-instance 'undefined-function-p-instruction
                         :result is-defined
                         :value result))
    (emit (make-instance 'branch-false-instruction
                         :value is-defined
                         :target out))
    ;; Not defined, fall back to FDEFINITION.
    (emit (make-instance 'constant-instruction
                         :destination fname-reg
                         :value (ast-name form)))
    (emit (make-instance 'call-instruction
                         :result result
                         :function 'fdefinition
                         :arguments (list fname-reg)))
    (emit (make-instance 'jump-instruction
                         :target out))
    (emit out)
    (ecase result-mode
      (:tail
       (emit (make-instance 'return-instruction
                            :value result))
       nil)
      ((:multiple :value :effect)
       result))))

(defmethod cg-form ((form ast-if) result-mode)
  (let ((else-label (make-instance 'label :name :if-else))
        (exit-label (make-instance 'label :name :if-exit))
        (test-value (cg-form (ast-test form) :value))
        (result (make-instance 'virtual-register :name :if-result))
        (exit-reached 0))
    (when (not test-value)
      (return-from cg-form nil))
    (emit (make-instance 'branch-false-instruction
                         :value test-value
                         :target else-label))
    (let ((then-value (cg-form (ast-if-then form) result-mode)))
      (when then-value
        (incf exit-reached)
        (ecase result-mode
          ((:multiple :tail)
           (when (not (eql then-value :multiple))
             (emit (make-instance 'values-instruction
                                  :values (list then-value)))))
          (:value
           (emit (make-instance 'move-instruction
                                :destination result
                                :source then-value)))
          (:effect))
        (emit (make-instance 'jump-instruction
                             :target exit-label))))
    (emit else-label)
    (let ((else-value (cg-form (ast-if-else form) result-mode)))
      (when else-value
        (incf exit-reached)
        (ecase result-mode
          ((:multiple :tail)
           (when (not (eql else-value :multiple))
             (emit (make-instance 'values-instruction
                                  :values (list else-value)))))
          (:value
           (emit (make-instance 'move-instruction
                                :destination result
                                :source else-value)))
          (:effect))
        (emit (make-instance 'jump-instruction
                             :target exit-label))))
    (when (zerop exit-reached)
      (return-from cg-form nil))
    (emit exit-label)
    (ecase result-mode
      ((:multiple :tail)
       :multiple)
      (:value
       result)
      (:effect
       :effect))))

(defmethod cg-form ((form ast-let) result-mode)
  (loop
     for (var init-form) in (ast-bindings form)
     do
       ;; Ensure there are no non-local variables or special bindings.
       (assert (and (lexical-variable-p var)
                    (localp var)))
       (cond ((zerop (lexical-variable-use-count var))
              (when (not (cg-form init-form :effect))
                (return-from cg-form nil)))
              (t
               (let ((reg (make-instance 'virtual-register :name var))
                     (value (cg-form init-form :value)))
                 (when (not value)
                   (return-from cg-form nil))
                 (setf (gethash var *variable-registers*) reg)
                 (emit (make-instance 'move-instruction
                                      :destination reg
                                      :source value))))))
  (cg-form (ast-body form) result-mode))

(defmethod cg-form ((form ast-multiple-value-bind) result-mode)
  (let ((value (cg-form (ast-value-form form) :multiple))
        (regs (loop
                 for var in (ast-bindings form)
                 for reg = (make-instance 'virtual-register :name var)
                 do (setf (gethash var *variable-registers*) reg)
                 collect reg)))
    (cond ((null value)
           (return-from cg-form nil))
          ((eql value :multiple)
           (emit (make-instance 'multiple-value-bind-instruction
                                :values regs)))
          (t
           ;; Single value result. First variable bound to the value, remaining
           ;; bound to NIL.
           (when (ast-bindings form)
             (emit (make-instance 'move-instruction
                                  :destination (gethash (first (ast-bindings form)) *variable-registers*)
                                  :source value)))
           (loop
              for var in (rest (ast-bindings form))
              for reg = (gethash var *variable-registers*)
              do
                (emit (make-instance 'constant-instruction
                                     :destination reg
                                     :value nil)))))
    (cg-form (ast-body form) result-mode)))

(defmethod cg-form ((form ast-multiple-value-call) result-mode)
  (let ((fn-tag (cg-form (ast-function-form form) :value)))
    (when (not fn-tag)
      (return-from cg-form nil))
    (let ((value-tag (cg-form (ast-value-form form) :multiple)))
      (when (not value-tag)
        (return-from cg-form nil))
      (cond ((eql value-tag :multiple)
             (ecase result-mode
               (:tail
                (emit (make-instance 'multiple-value-funcall-multiple-instruction
                                     :function fn-tag))
                (emit (make-instance 'return-multiple-instruction))
                nil)
               (:multiple
                (emit (make-instance 'multiple-value-funcall-multiple-instruction
                                     :function fn-tag))
                :multiple)
               ((:value :effect)
                (let ((result (make-instance 'virtual-register)))
                  (emit (make-instance 'multiple-value-funcall-instruction
                                       :result result
                                       :function fn-tag))
                  result))))
            (t
             (ecase result-mode
               (:tail
                (emit (make-instance 'funcall-multiple-instruction
                                     :function fn-tag
                                     :arguments (list value-tag)))
                (emit (make-instance 'return-multiple-instruction))
                nil)
               (:multiple
                (emit (make-instance 'funcall-multiple-instruction
                                     :function fn-tag
                                     :arguments (list value-tag)))
                :multiple)
               ((:value :effect)
                (let ((result (make-instance 'virtual-register)))
                  (emit (make-instance 'funcall-instruction
                                       :result result
                                       :function fn-tag
                                       :arguments (list value-tag)))
                  result))))))))

(defmethod cg-form ((form ast-multiple-value-prog1) result-mode)
  (when (eql result-mode :tail)
    (setf result-mode :multiple))
  (let ((value (cg-form (ast-value-form form) result-mode))
        (context (make-instance 'virtual-register))
        (*dynamic-stack* *dynamic-stack*))
    (when (not value)
      (return-from cg-form nil))
    (when (eql value :multiple)
      (emit (make-instance 'save-multiple-instruction
                           :context context))
      (push `(:saved-mv ,context) *dynamic-stack*))
    (when (not (cg-form (ast-body form) :effect))
      (return-from cg-form nil))
    (when (eql value :multiple)
      (emit (make-instance 'restore-multiple-instruction
                           :context context)))
    value))

(defmethod cg-form ((form ast-progn) result-mode)
  (if (ast-forms form)
      (do ((i (ast-forms form) (rest i)))
          ((endp (rest i))
           (cg-form (first i) result-mode))
        (when (not (cg-form (first i) :effect))
          (return-from cg-form nil)))
      (cg-form (make-instance 'ast-quote :value nil) result-mode)))

(defmethod cg-form ((form ast-quote) result-mode)
  (ecase result-mode
    (:tail
     (let ((result (make-instance 'virtual-register)))
       (emit (make-instance 'constant-instruction
                            :destination result
                            :value (ast-value form)))
       (emit (make-instance 'return-instruction
                            :value result))
       nil))
     ((:multiple :value)
      (let ((result (make-instance 'virtual-register)))
        (emit (make-instance 'constant-instruction
                             :destination result
                             :value (ast-value form)))
        result))
     (:effect
      :effect)))

(defmethod cg-form ((form ast-setq) result-mode)
  (let ((var (ast-setq-variable form))
        (value (cg-form (ast-value form) :value)))
    (assert (localp var))
    (when (not value)
      (return-from cg-form nil))
    (emit (make-instance 'move-instruction
                         :destination (gethash var *variable-registers*)
                         :source value))
    value))

(defun tagbody-localp (info)
  (dolist (tag (tagbody-information-go-tags info) t)
    (unless (or (null (go-tag-used-in tag))
                (and (null (cdr (go-tag-used-in tag)))
                     (eq (car (go-tag-used-in tag)) (lexical-variable-definition-point info))))
      (return nil))))

(defmethod cg-form ((form ast-tagbody) result-mode)
  (let* ((need-exit-label nil)
         (exit-label (make-instance 'label :name :tagbody-exit))
         (info (ast-info form))
         (escapes (not (tagbody-localp info)))
         (escape-reg (make-instance 'virtual-register :name :tagbody-nlx))
         (tag-labels (loop
                        for tag in (tagbody-information-go-tags info)
                        collect (make-instance 'label :name (go-tag-name tag))))
         (thunk-labels (loop
                          for tag in (tagbody-information-go-tags info)
                          collect (make-instance 'label :name `(:nlx-thunk ,(go-tag-name tag)))))
         (*dynamic-stack* *dynamic-stack*)
         (nlx-region (make-instance 'begin-nlx-instruction
                                    :context escape-reg
                                    :targets thunk-labels)))
    (when escapes
      (emit nlx-region)
      (setf (gethash info *variable-registers*) escape-reg)
      (push `(:nlx ,escape-reg ,nlx-region) *dynamic-stack*))
    (loop
       for tag in (tagbody-information-go-tags info)
       for label in tag-labels
       do (setf (gethash tag *go-tag-and-block-labels*) (list label *dynamic-stack*)))
    ;; Jump to the entry point.
    (emit (make-instance 'jump-instruction
                         :target (first (gethash (first (first (ast-statements form)))
                                                 *go-tag-and-block-labels*))))
    ;; Emit labels & statements.
    (loop
       for (go-tag stmt) in (ast-statements form)
       do
         (emit (first (gethash go-tag *go-tag-and-block-labels*)))
         (when (cg-form stmt :effect)
           (setf need-exit-label t)
           (emit (make-instance 'jump-instruction
                                :target exit-label))))
    ;; Emit all the NLX thunks.
    (when escapes
      (loop
         for thunk-label in thunk-labels
         for tag-label in tag-labels
         do
           (emit thunk-label)
           (emit (make-instance 'nlx-entry-instruction
                                :region nlx-region
                                :context escape-reg
                                :value (make-instance 'virtual-register)))
           (emit (make-instance 'jump-instruction
                                :target tag-label))))
    ;; Exit label.
    (cond (need-exit-label
           (emit exit-label)
           (when escapes
             (emit (make-instance 'finish-nlx-instruction
                                  :region nlx-region
                                  :context escape-reg)))
           (cg-form (make-instance 'ast-quote :value nil) result-mode))
          (t
           nil))))

(defmethod cg-form ((form ast-go) result-mode)
  (let ((label (gethash (ast-target form) *go-tag-and-block-labels*)))
    (cond (label ; local jump
           (unwind-dynamic-stack-to (second label))
           (emit (make-instance 'jump-instruction
                                :target (first label))))
          (t ; Non-local exit
           (let ((tagbody-tag (cg-form (ast-info form) :value))
                 (index (position (ast-target form)
                                  (tagbody-information-go-tags
                                   (go-tag-tagbody (ast-target form))))))
             (let ((nil-val (cg-form (make-instance 'ast-quote :value nil) :value)))
               (emit (make-instance 'invoke-nlx-instruction
                                    :context tagbody-tag
                                    :index index
                                    :value nil-val)))))))
  nil)

(defmethod cg-form ((form ast-the) result-mode)
  (cg-form (ast-value form) result-mode))

(defun cg-funcall (form result-mode)
  (let* ((arguments (loop
                       for arg in (ast-arguments form)
                       collect (let ((value (cg-form arg :value)))
                                 (when (not value)
                                   (return-from cg-funcall nil))
                                 value)))
         (function (first arguments)))
    (cond ((eql result-mode :tail)
           (emit (make-instance 'funcall-multiple-instruction
                                :function function
                                :arguments (rest arguments)))
           (emit (make-instance 'return-multiple-instruction))
           nil)
          ((eql result-mode :multiple)
           (emit (make-instance 'funcall-multiple-instruction
                                :function function
                                :arguments (rest arguments)))
           :multiple)
          (t
           (let ((result (make-instance 'virtual-register)))
             (emit (make-instance 'funcall-instruction
                                  :result result
                                  :function function
                                  :arguments (rest arguments)))
             result)))))

(defun cg-values (form result-mode)
  (cond ((endp (ast-arguments form))
         ;; Zero values
         (ecase result-mode
           (:tail
            (emit (make-instance 'values-instruction
                                 :values '()))
            (emit (make-instance 'return-multiple-instruction))
            nil)
           (:multiple
            (emit (make-instance 'values-instruction
                                 :values '()))
            :multiple)
           (:value
            ;; Zero values in a single-value context evaluates to nil.
            (cg-form (make-instance 'ast-quote :value nil) :value))
           (:effect
            :effect)))
        ((endp (rest (ast-arguments form)))
         ;; One value
         (cg-form (first (ast-arguments form))
                  (if (member result-mode '(:tail :multiple))
                      :value
                      result-mode)))
        ((eql result-mode :effect)
         ;; Like PROGN
         (loop
            for arg in (ast-arguments form)
            do (when (not (cg-form arg :effect))
                 (return-from cg-values nil))))
        ((eql result-mode :value)
         ;; Like PROG1
         (let ((first-value (cg-form (first (ast-arguments form)) :value)))
           (when (not first-value)
             (return-from cg-values nil))
           (loop
              for arg in (rest (ast-arguments form))
              do (when (not (cg-form arg :effect))
                   (return-from cg-values nil)))
           first-value))
        (t
         ;; Multiple values
         (let ((arguments (loop
                             for arg in (ast-arguments form)
                             collect (let ((value (cg-form arg (if (eql result-mode :effect)
                                                                   :effect
                                                                   :value))))
                                       (when (not value)
                                         (return-from cg-values nil))
                                       value))))
           (ecase result-mode
             (:tail
              (emit (make-instance 'values-instruction
                                   :values arguments))
              (emit (make-instance 'return-multiple-instruction))
              nil)
             (:multiple
              (emit (make-instance 'values-instruction
                                   :values arguments))
              :multiple))))))

(defun cg-call (form result-mode)
  (let ((arguments (loop
                      for arg in (ast-arguments form)
                      collect (let ((value (cg-form arg :value)))
                                (when (not value)
                                  (return-from cg-call nil))
                                value))))
    (cond ((eql result-mode :tail)
           (emit (make-instance 'call-multiple-instruction
                                :function (ast-name form)
                                :arguments arguments))
           (emit (make-instance 'return-multiple-instruction))
           nil)
          ((eql result-mode :multiple)
           (emit (make-instance 'call-multiple-instruction
                                :function (ast-name form)
                                :arguments arguments))
           :multiple)
          (t
           (let ((result (make-instance 'virtual-register)))
             (emit (make-instance 'call-instruction
                                  :result result
                                  :function (ast-name form)
                                  :arguments arguments))
             result)))))

(defclass primitive ()
  ((%name :initarg :name :reader primitive-name)
   (%lambda-list :initarg :lambda-list :reader primitive-lambda-list)
   (%emitter :initarg :emitter :reader primitive-emitter)))

(defvar *primitives* (make-hash-table :test 'equal))

(defmacro define-primitive (name (lambda-list result-mode) &body body)
  `(setf (gethash ',name *primitives*)
         (make-instance 'primitive
                        :name ',name
                        :lambda-list ',lambda-list
                        :emitter (lambda (,result-mode ,@lambda-list)
                                   (declare (ignorable ,result-mode))
                                   ,@body))))

(define-primitive sys.int::%object-ref-t ((object offset) result-mode)
  (let ((result (make-instance 'virtual-register)))
    (emit (make-instance 'object-get-t-instruction
                         :destination result
                         :object object
                         :index offset))
    result))

(define-primitive (setf sys.int::%object-ref-t) ((value object offset) result-mode)
  (emit (make-instance 'object-set-t-instruction
                       :value value
                       :object object
                       :index offset))
  value)

(define-primitive mezzano.runtime::%fixnum-< ((lhs rhs) result-mode)
  (let ((result (make-instance 'virtual-register)))
    (emit (make-instance 'fixnum-<-instruction
                         :result result
                         :lhs lhs
                         :rhs rhs))
    result))

(define-primitive sys.int::%%push-special-stack ((a b) result-mode)
  (emit (make-instance 'push-special-stack-instruction
                       :a-value a
                       :b-value b))
  a)

(define-primitive sys.int::%%bind ((symbol value) result-mode)
  (emit (make-instance 'push-special-stack-instruction
                       :a-value symbol
                       :b-value value))
  (emit (make-instance 'flush-binding-cache-entry-instruction
                       :symbol symbol))
  value)

(define-primitive sys.int::%%unbind (() result-mode)
  (emit (make-instance 'unbind-instruction))
  (let ((result (make-instance 'virtual-register)))
    (emit (make-instance 'constant-instruction
                         :destination result
                         :value nil))
    result))

(define-primitive sys.int::%%disestablish-block-or-tagbody (() result-mode)
  (emit (make-instance 'disestablish-block-or-tagbody-instruction))
  (let ((result (make-instance 'virtual-register)))
    (emit (make-instance 'constant-instruction
                         :destination result
                         :value nil))
    result))

(define-primitive sys.int::%%disestablish-unwind-protect (() result-mode)
  (emit (make-instance 'disestablish-unwind-protect-instruction))
  (let ((result (make-instance 'virtual-register)))
    (emit (make-instance 'constant-instruction
                         :destination result
                         :value nil))
    result))

(defun cg-primitive (primitive form result-mode)
  (let ((arguments (loop
                      for arg in (ast-arguments form)
                      collect (let ((value (cg-form arg :value)))
                                (when (not value)
                                  (return-from cg-primitive nil))
                                value))))
    (apply (primitive-emitter primitive) result-mode arguments)))

(defmethod cg-form ((form ast-call) result-mode)
  (let ((prim (gethash (ast-name form) *primitives*)))
    (cond ((and (eql (ast-name form) 'mezzano.runtime::%funcall)
                (ast-arguments form))
           (cg-funcall form result-mode))
          ((eql (ast-name form) 'values)
           (cg-values form result-mode))
          ((eql (ast-name form) 'sys.c::make-dx-simple-vector)
           (assert (eql (length (ast-arguments form)) 1))
           (assert (typep (first (ast-arguments form)) 'ast-quote))
           (check-type (ast-value (first (ast-arguments form))) (integer 0))
           (let ((result (make-instance 'virtual-register)))
             (emit (make-instance 'make-dx-simple-vector-instruction
                                  :result result
                                  :size (ast-value (first (ast-arguments form)))))
             result))
          ((eql (ast-name form) 'sys.c::make-dx-closure)
           (assert (eql (length (ast-arguments form)) 2))
           (let ((result (make-instance 'virtual-register)))
             (emit (make-instance 'make-dx-closure-instruction
                                  :result result
                                  :function (cg-form (first (ast-arguments form)) :value)
                                  :environment (cg-form (second (ast-arguments form)) :value)))
             result))
          ((and prim
                (eql (length (primitive-lambda-list prim))
                     (length (ast-arguments form))))
           (cg-primitive prim form result-mode))
          (t
           (cg-call form result-mode)))))

(defun local-go-p (form)
  (and (typep form 'ast-go)
       (gethash (ast-target form) *go-tag-and-block-labels*)))

(defmethod cg-form ((form ast-jump-table) result-mode)
  (let* ((value (ast-value form))
         (jumps (ast-targets form))
         (tag (cg-form value :value))
         (exit-label (make-instance 'label :name :jump-table-exit))
         (need-exit nil)
         (targets
          (loop
             for j in jumps
             collect (if (local-go-p j)
                         (first (gethash (ast-target j) *go-tag-and-block-labels*))
                         (make-instance 'label :name :jump-table-target)))))
    (when (not tag)
      (return-from cg-form nil))
    (emit (make-instance 'switch-instruction
                         :value tag
                         :targets targets))
    (loop
       for j in jumps
       for targ in targets
       when (not (local-go-p j))
       do
         (emit targ)
         (let ((tag (cg-form j :effect)))
           (when tag
             (setf need-exit t)
             (emit (make-instance 'jump-instruction
                                  :target exit-label)))))
    (cond (need-exit
           (emit exit-label)
           (cg-form (make-instance 'ast-quote :value nil) result-mode))
          (t
           nil))))

(defmethod cg-form ((form lexical-variable) result-mode)
  (assert (localp form))
  (ecase result-mode
    (:tail
     (emit (make-instance 'return-instruction
                          :value (gethash form *variable-registers*)))
     nil)
    ((:multiple :value)
     (let ((result (make-instance 'virtual-register))
           (reg (gethash form *variable-registers*)))
       (emit (make-instance 'move-instruction
                            :destination result
                            :source reg))
       result))
    (:effect
     :effect)))

(defmethod cg-form ((form lambda-information) result-mode)
  (ecase result-mode
     (:tail
      (let ((result (make-instance 'virtual-register)))
        (emit (make-instance 'constant-instruction
                             :destination result
                             :value (codegen-lambda form)))
        (emit (make-instance 'return-instruction
                             :value result))
        nil))
     ((:multiple :value)
      (let ((result (make-instance 'virtual-register)))
        (emit (make-instance 'constant-instruction
                             :destination result
                             :value (codegen-lambda form)))
        result))
     (:effect
      :effect)))