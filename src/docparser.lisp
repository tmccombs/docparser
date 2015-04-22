(in-package :cl-user)
(defpackage docparser
  (:use :cl)
  (:import-from :trivial-types
                :proper-list)
  (:import-from :alexandria
                :destructuring-case)
  ;; Classes
  (:export :symbol-node
           :documentation-node
           :operator-node
           :function-node
           :macro-node
           :generic-function-node
           :method-node
           :variable-node
           :slot-node
           :record-node
           :struct-node
           :class-node
           :type-node)
  ;; Interface
  (:export :parse)
  (:documentation "Parse documentation from ASDF systems."))
(in-package :docparser)

;;; Classes

(defclass symbol-node ()
  ((symbol-node-package :reader symbol-node-package
                        :initarg :package
                        :type string
                        :documentation "A symbol's package name.")
   (symbol-node-name :reader symbol-node-name
                     :initarg :name
                     :type string
                     :documentation "A symbol's name.")
   (externalp :reader symbol-external-p
              :initarg :externalp
              :type boolean
              :documentation "Whether the symbol is external to the package.")
   (setfp :reader symbol-setf-p
          :initarg :setfp
          :initform nil
          :type boolean
          :documentation "Whether the symbol is a setf method."))
  (:documentation "A symbol."))

(defclass documentation-node ()
  ((node-name :reader node-name
              :initarg :name
              :type symbol-node
              :documentation "The symbol name of the operator, variable, or class.")
   (node-docstring :reader node-docstring
                   :initarg :docstring
                   :type (or null string)
                   :documentation "The node's documentation."))
  (:documentation "Superclass for all documentation nodes."))

(defclass operator-node (documentation-node)
 ((lambda-list :reader operator-lambda-list
               :initarg :lambda-list
               :documentation "The operator's lambda list."))
  (:documentation "The base class of functions and macros."))

(defclass function-node (operator-node)
  ()
  (:documentation "A function."))

(defclass macro-node (operator-node)
  ()
  (:documentation "A macro."))

(defclass generic-function-node (operator-node)
  ()
  (:documentation "A generic function."))

(defclass method-node (operator-node)
  ()
  (:documentation "A method."))

(defclass variable-node (documentation-node)
  ()
  (:documentation "A variable."))

(defclass slot-node (documentation-node)
  ((accessors :reader slot-accessors
              :initarg :accessors
              :initform nil
              :type (proper-list symbol-node))
   (readers :reader slot-readers
            :initarg :readers
            :initform nil
            :type (proper-list symbol-node))
   (writers :reader slot-writers
            :initarg :writers
            :initform nil
            :type (proper-list symbol-node)))
  (:documentation "A class or structure slot."))

(defclass record-node (documentation-node)
  ((slots :reader record-slots
          :initarg :slots
          :type (proper-list slot-node)
          :documentation "A list of slots.")))

(defclass struct-node (record-node)
  ()
  (:documentation "A structure."))

(defclass class-node (record-node)
  ()
  (:documentation "A class."))

(defclass type-node (operator-node)
  ()
  (:documentation "A type."))

;;; Constructors

(defun cl-symbol-external-p (symbol)
  "Whether or not a symbol is external."
  (multiple-value-bind (sym status)
      (find-symbol (symbol-name symbol)
                   (symbol-package symbol))
    (declare (ignore sym))
    (eq status :external)))

(defun symbol-node-from-symbol (symbol &key setf)
  "Build a symbol node from a Common Lisp symbol."
  (make-instance 'symbol-node
                 :package (package-name (symbol-package symbol))
                 :name (symbol-name symbol)
                 :externalp (cl-symbol-external-p symbol)
                 :setfp setf))

;;; Methods

(defun render-full-symbol (symbol-node)
  "Render a symbol into a string."
  (concatenate 'string
               (symbol-node-package symbol-node)
               ":"
               (symbol-node-name symbol-node)))

(defun render-humanize (symbol-node)
  "Render a symbol into a string in a human-friendly way."
  (string-downcase (symbol-node-name symbol-node)))

;;; Printing

(defmethod print-object ((symbol symbol-node) stream)
  "Print a symbol node."
  (print-unreadable-object (symbol stream)
    (format stream "symbol ~A" (render-full-symbol symbol))))

(defmethod print-object ((operator operator-node) stream)
  "Print an operator node."
  (print-unreadable-object (operator stream)
    (format stream "~A ~A ~A"
            (typecase operator
              (function-node "function")
              (macro-node "macro")
              (generic-function-node "generic function")
              (method "method")
              (t "operator"))
            (let ((name (node-name operator)))
              (if (symbol-setf-p name)
                  (format nil "(setf ~A)" (render-humanize name))
                  (render-humanize name)))
            (operator-lambda-list operator))))

;;; Parsing

(defun load-system (system-name)
  "Load an ASDF system by name."
  (uiop:with-muffled-loader-conditions ()
    (uiop:with-muffled-compiler-conditions ()
      (asdf:load-system system-name :verbose nil :force t))))

(defparameter *parsers* (list)
  "A list of symbols to the functions used to parse their corresponding forms.")

(defmacro define-parser (name (form) &body body)
  "Define a parser."
  `(push (cons ',name (lambda (,form)
                        ,@body))
         *parsers*))

(defun parse-form (form)
  "Parse a form into a node."
  (when (listp form)
    (let ((parser (rest (assoc (first form) *parsers*))))
      (when parser
        (funcall parser (rest form))))))

(defun parse (system-name)
  (let* ((nodes (list))
         (old-macroexpander *macroexpand-hook*)
         (*macroexpand-hook*
           #'(lambda (function form environment)
               (let ((parsed (parse-form form)))
                 (if parsed
                     (progn
                       (push parsed nodes)
                       `(identity t))
                     (funcall old-macroexpander
                              function
                              form
                              environment))))))
    (load-system system-name)
    nodes))

;;; Parsers

(define-parser cl:defun (form)
  (destructuring-bind (name (&rest args) &rest body) form
    (let ((docstring (if (stringp (first body))
                         (first body)
                         nil)))
      (make-instance 'function-node
                     :name (if (listp name)
                               ;; SETF name
                               (symbol-node-from-symbol (second name)
                                                        :setf t)
                               ;; Regular name
                               (symbol-node-from-symbol name))
                     :docstring docstring
                     :lambda-list args))))

(define-parser cl:defmacro (form)
  (destructuring-bind (name (&rest args) &rest body) form
    (let ((docstring (if (stringp (first body))
                         (first body)
                         nil)))
      (make-instance 'macro-node
                     :name (symbol-node-from-symbol name)
                     :docstring docstring
                     :lambda-list args))))

(define-parser cl:defgeneric (form)
  t)

(define-parser cl:defmethod (form)
  (destructuring-bind (name (&rest args) &rest body) form
    (let ((docstring (if (stringp (first body))
                         (first body)
                         nil)))
      (make-instance 'method-node
                     :name (if (listp name)
                               ;; SETF name
                               (symbol-node-from-symbol (second name)
                                                        :setf t)
                               ;; Regular name
                               (symbol-node-from-symbol name))
                     :docstring docstring
                     :lambda-list args))))