;;;; settings

(setf *print-circle* t)			;we have cyclic data structures

(defmacro dofromto (spec &rest body)
  (destructuring-bind (var from to)
      spec
    `(do ((,var ,from (1+ ,var)))
      ((> ,var ,to))
      ,@body)))

(defmacro letmv (spec &rest body)
  (labels ((expand (spec)
	     (if (null spec)
		 `(progn ,@body)
		 `(multiple-value-bind ,(caar spec)
		   ,(cadar spec)
		   ,(expand (cdr spec))))))
    (expand spec)))

(defun my-macroexpand (sexp macros)
  (labels ((expand (sexp)
	     (if (consp sexp)
		 (if (symbolp (car sexp))
		     (let ((macro (cdr (assoc (car sexp) macros))))
		       (if macro
			   (expand (apply macro (cdr sexp)))
			   (cons (car sexp) (mapcar #'expand (cdr sexp)))))
		     (mapcar #'expand sexp))
		 sexp)))
    (expand sexp)))

(defun sort-by-fixed-order (lst order)
  (sort lst #'(lambda (a b) (< (position a order) (position b order)))))

(defun mappend (func lst)
  (apply #'append (mapcar func lst)))

(defun mapcar* (func &rest lists)
  (remove nil (apply #'mapcar func lists)))

;;; do a mapcar with a function returning two values. return two
;;; lists.  e.g.: (mapcar-mapcar #'(lambda (x) (values (car x) (cdr
;;; x))) '((1 . a) (2 . b) (3 . c))) => (1 2 3), (a b c)

(defun mapcar-mapcar (func &rest lists)
  (if (null (car lists))
      (values nil nil)
      (multiple-value-bind (val1 val2)
	  (apply func (mapcar #'car lists))
	(multiple-value-bind (rest1 rest2)
	    (apply #'mapcar-mapcar func (mapcar #'cdr lists))
	  (values (cons val1 rest1)
		  (cons val2 rest2))))))

(defun choices (&rest choices)
  choices)

(defun all-choices (expr)
  expr)

(defmacro collect-choices (structure expr &rest body)
  (let ((choice-name (gensym)))
    `(mappend #'(lambda (,choice-name)
		  (destructuring-bind ,structure
		      ,choice-name
		    ,@body))
      ,expr)))

(defun combine-choices (&rest choices-lists)
  (apply #'append choices-lists))

(defun dcs (x)
  (string-downcase (symbol-name x)))

(defstruct insn
  name
  fields
  field-equivalences
  effect
  asm
  operands
  known-bits
  known-bit-values
  operand-bits
  dont-care-bits
  generate
  (generators nil))

(defstruct register-class
  name
  type
  width
  number-width
  start-index)

(defstruct register
  name
  register-class
  number)

(defstruct subregister
  name
  register
  begin
  end)

(defvar *expand-transformation* nil)

(defstruct expr
  kind
  (constp-value 'dont-know)
  (type nil)
  (width nil)
  (operands nil)
  (alternatives-value nil)
  (expanded-transformation-p *expand-transformation*))

(defmacro expr-case (expr &rest choices)
  (let ((expr-name (gensym)))
    `(let ((,expr-name ,expr))
      (case (expr-kind ,expr)
	,@(mapcar #'(lambda (choice)
		      (if (eq (first choice) t)
			  `(t ,@(rest choice))
			  `(,(first choice)
			    (destructuring-bind ,(second choice)
				(expr-operands ,expr)
			      ,@(cddr choice)))))
		  choices)
	,@(if (member t (mapcar #'car choices))
	      nil
	      `((t
		 (error "expr not recognized: ~A~%" ,expr-name))))))))

(defstruct mnemonic
  name
  args
  substitution)

(defstruct generator
  inputs
  result
  pattern
  code)

(defstruct machine
  name
  (insn-bits nil)
  (word-bits nil)
  (single-bits nil)
  (double-bits nil)
  (fields nil)
  (operand-order nil)
  (register-classes nil)
  (registers nil)
  (subregisters nil)
  (insn-macros nil)
  (insns nil)
  (mnemonics nil)
  (generators nil))

(defparameter *this-machine* nil)

(defvar *tmp-num* 0)

(defvar *take-fields-from-variables* nil)

(defstruct transformation
  pattern
  substitution)

(defvar *transformations* nil)

(defvar *used-target-insns* :all)

;;; returns nil if not successful or t and a list of the bindings
;;; otherwise.
(defun match-sexpr (pattern expr)
  (cond ((integerp pattern)
	 (if (or (and (integerp expr) (= pattern expr))
		 (and (eq (expr-kind expr) 'integer) (= pattern (first (expr-operands expr)))))
	     (values t nil)
	     nil))
	((eq (first pattern) 'match)
	 (let* ((name (second pattern))
		(props (cddr pattern))
		(width (getf props :width))
		(type (getf props :type)))
	   (cond ((not (expr-p expr))
		  (values t (list (cons name expr))))
		 ((and (or (null width) (symbolp width) (= width (expr-width expr)))
		       (or (null type) (eq type (expr-type expr))))
		  (values t (cons (cons name expr)
				  (if (and (not (null width)) (symbolp width))
				      (list (cons width (expr-width expr)))
				      nil))))
		 (t
		  nil))))
	(t
	 (let ((kind (first pattern))
	       (operands (rest pattern)))
	   (if (eq kind (expr-kind expr))
	       (multiple-value-bind (successes bindings)
		   (mapcar-mapcar #'match-sexpr operands (expr-operands expr))
		 (if (notany #'null successes)
		     (values t (apply #'append bindings))
		     nil)))))))

;;; returns a list of the variables bound if pattern is matched
;;; against an expression.  the order of the variables in the list is
;;; the same as the one match-sexpr would return with the same
;;; pattern.
(defun sexpr-variables (pattern)
  (cond ((integerp pattern)
	 nil)
	((eq (first pattern) 'match)
	 (let* ((name (second pattern))
		(props (cddr pattern))
		(width (getf props :width)))
	   (cons name
		 (if (and (not (null width)) (symbolp width))
		     (list width)
		     nil))))
	(t
	 (let ((kind (first pattern))
	       (operands (rest pattern)))
	   (mappend #'sexpr-variables operands)))))

(defmacro if-match (pattern expr cons alt)
  (let ((variables (sexpr-variables pattern))
	(success (gensym))
	(bindings (gensym)))
    `(multiple-value-bind (,success ,bindings)
      (match-sexpr ',pattern ,expr)
      (if ,success
	  (destructuring-bind ,variables
	      (mapcar #'cdr ,bindings)
	    ,cons)
	  ,alt))))

(defun new-machine (name)
  (setf *this-machine* (make-machine :name name))
  (setf *tmp-num* 0))

(defun define-register-class (name type width registers)
  (let ((class (make-register-class :name name
				    :type type
				    :width width
				    :number-width (ceiling (log (length registers) 2))
				    :start-index (length (machine-registers *this-machine*)))))
    (push class (machine-register-classes *this-machine*))
    (do ((registers registers (cdr registers))
	 (i 0 (1+ i)))
	((null registers))
      (push (make-register :name (car registers)
			   :register-class class
			   :number i)
	    (machine-registers *this-machine*)))))

(defun registerp (expr)
  (if (and (symbolp expr)
	   (find expr (machine-registers *this-machine*) :key #'register-name))
      t
      nil))

(defun lookup-register (name)
  (find name (machine-registers *this-machine*) :key #'register-name))

(defun lookup-register-class (name &optional (machine *this-machine*))
  (find name (machine-register-classes machine) :key #'register-class-name))

(defun define-subregisters (subregisters)
  (dolist (subregister subregisters)
    (destructuring-bind (name register-name begin end)
	subregister
      (let ((register (lookup-register register-name)))
	(when (null register)
	  (error "not a register: ~A~%" register-name))
	(unless (eq (register-class-type (register-register-class register)) 'integer)
	  (error "only subregisters of integer registers are allowed: ~A~%" name))
	(push (make-subregister :name name
				:register register
				:begin begin
				:end end)
	      (machine-subregisters *this-machine*))))))

(defun subregisterp (expr)
  (if (and (symbolp expr)
	   (find expr (machine-subregisters *this-machine*) :key #'subregister-name))
      t
      nil))

(defun lookup-subregister (name)
  (find name (machine-subregisters *this-machine*) :key #'subregister-name))

(defun define-fields (fields)
  (dolist (field fields)
    (destructuring-bind (name begin end)
	field
      (when (assoc name (machine-fields *this-machine*))
	(error "field already defined: ~A~%" name))
      (setf (machine-fields *this-machine*)
	    (acons name (make-expr :kind 'field :type 'integer :width (1+ (- end begin)) :operands (list name begin end))
		   (machine-fields *this-machine*))))))

(defun fieldp (expr)
  (if (and (symbolp expr)
	   (assoc expr (machine-fields *this-machine*)))
      t
      nil))

(defun lookup-field (name)
  (let ((expr (cdr (assoc name (machine-fields *this-machine*)))))
    (destructuring-bind (name begin end)
	(expr-operands expr)
      (values begin end expr))))

(defun define-operand-order (order)
  (setf (machine-operand-order *this-machine*) order))

(defun integer-to-bit-vector (x &optional (num-bits (machine-insn-bits *this-machine*)))
  (let ((bits (make-array num-bits :element-type 'bit :initial-element 0)))
    (dofromto (i 0 (1- num-bits))
      (when (logbitp i x)
	(setf (bit bits i) 1)))
    bits))

(defun bit-vector-to-integer (v)
  (let ((x 0))
    (dofromto (i 0 (1- (length v)))
      (when (= (bit v i) 1)
	(incf x (expt 2 i))))
    x))

(defun integer-bit-range (begin end)
  (ash (1- (expt 2 (1+ (- end begin)))) begin))

(defun bit-range (begin end &optional (num-bits (machine-insn-bits *this-machine*)))
  (integer-to-bit-vector (integer-bit-range begin end) num-bits))

(defun mask (begin end width)
  (if (< end begin)
      (+ (- (1- (ash 1 width)) (1- (ash 1 begin))) (1- (ash 1 (1+ end))))
      (- (1- (ash 1 (1+ end))) (1- (ash 1 begin)))))

(defun invert-maskmask (bit-width value)
  (let ((bit-mask (1- (ash 1 bit-width))))
    (labels ((invert (value)
	       (if (zerop value)
		   0
		   (let* ((bits (logand value bit-mask))
			  (rest (ash value (- bit-width)))
			  (rest-result (invert rest)))
		     (if (null rest-result)
			 nil
			 (cond ((zerop bits)
				(ash rest-result 1))
			       ((= bits bit-mask)
				(logior (ash rest-result 1) 1))
			       (t
				nil)))))))
      (invert value))))

(defun sign-extend (x src dst)
  (ecase (ash x (- (1- src)))
    (0 x)
    (1 (logior x (ash (1- (ash 1 (- dst src))) src)))))

(defun subst-many (new old sexp)
  (if (null new)
      sexp
      (subst-many (cdr new) (cdr old) (subst (car new) (car old) sexp))))

(defmacro define-insn-macro (name arg-names subst)
  `(push (cons ',name #'(lambda (&rest args) (subst-many args ',arg-names ',subst)))
    (machine-insn-macros *this-machine*)))

(defmacro define-insn (name fields-spec effect asm &key (generate t))
  (when (assoc name (machine-insns *this-machine*))
    (error "insn already defined: ~A~%" name))
  (let* ((known-bits (make-array (machine-insn-bits *this-machine*) :element-type 'bit :initial-element 0))
	 (known-bit-values (make-array (machine-insn-bits *this-machine*) :element-type 'bit :initial-element 0))
	 (dont-care-bits (make-array (machine-insn-bits *this-machine*) :element-type 'bit :initial-element 0))
	 (effect (mapcar #'(lambda (expr) (generate-expr expr nil nil nil)) (my-macroexpand effect (machine-insn-macros *this-machine*))))
	 (operands  (sort-by-fixed-order (fields-in-expr effect) (machine-operand-order *this-machine*)))
	 (operand-bits (make-array (machine-insn-bits *this-machine*) :element-type 'bit :initial-element 0))
	 (fields nil)
	 (field-equivalences nil)
	 (field-equivalences-bits (make-array (machine-insn-bits *this-machine*) :element-type 'bit :initial-element 0)))
    (dolist (operand-field operands)
      (multiple-value-bind (begin end)
	  (lookup-field operand-field)
	(dofromto (i begin end)
	  (when (= (bit operand-bits i) 1)
	    (error "overlapping operands in insn ~A~%" name))
	  (setf (bit operand-bits i) 1))))
    (dolist (field fields-spec)
      (destructuring-bind (field-name value)
	  field
	(multiple-value-bind (begin end)
	    (lookup-field field-name)
	  (when (and (integerp value)
		     (or (< value 0)
			 (>= value (expt 2 (1+ (- end begin))))))
	    (error "value ~A does not fit into field ~A in insn ~A" value field-name name))
	  (dofromto (i begin end)
	    (when (or (= (bit known-bits i) 1)
		      (= (bit dont-care-bits i) 1))
	      (error "insn ~A specifies bit ~A more than once~%" name i))
	    (when (= (bit operand-bits i) 1)
	      (error "non-operand bits are used in operands in insn ~A~%" name))
	    (cond ((eq value 'dont-care)
		   (setf (bit dont-care-bits i) 1))
		  ((symbolp value)
		   (setf (bit field-equivalences-bits i) 1))
		  (t
		   (setf (bit known-bits i) 1))))
	  (cond ((and (symbolp value) (not (eq value 'dont-care)))
		 (unless (member value operands)
		   (error "illegal field equivalence in insn ~A~%" name))
		 (push (cons field-name value) field-equivalences))
		((integerp value)
		 (push (cons field-name value) fields)
		 (bit-ior known-bit-values (integer-to-bit-vector (ash value begin)) known-bit-values))))))
    (when (find 0 (reduce #'bit-ior (list known-bits dont-care-bits operand-bits field-equivalences-bits)))
      (error "not all bits are specified in insn ~A~%" name))
    `(push (make-insn :name ',name
	              :fields ',fields
	              :field-equivalences ',field-equivalences
	              :effect ',effect
	              :asm ',asm
	              :operands ',operands
	              :known-bits ,known-bits
	              :known-bit-values ,known-bit-values
	              :operand-bits ,operand-bits
	              :dont-care-bits ,dont-care-bits
	              :generate ,generate)
           (machine-insns *this-machine*))))

(defmacro define-mnemonic (name args substitution)
  `(push (make-mnemonic :name ',name
	                :args ',args
	                :substitution ',substitution)
         (machine-mnemonics *this-machine*)))

(defmacro define-generator (&key inputs result pattern code)
  `(push (make-generator :inputs ',inputs :result ',result :pattern ',pattern :code ',code) (machine-generators *this-machine*)))

(defmacro define-transformation (pattern substitution)
  `(push (make-transformation :pattern ',pattern :substitution ',substitution) *transformations*))

(defun expr-constp (expr)
  (when (eq (expr-constp-value expr) 'dont-know)
    (setf (expr-constp-value expr)
	  (case (expr-kind expr)
	    ((integer float field string pc addr input) t)
	    ((mem register subregister numbered-subregister) nil)
	    ((symbol) nil)		;FIXME
	    ((let ignore set jump nop system-call call-pal not-implemented) nil)
	    (t (every #'expr-constp (remove-if-not #'expr-p (expr-operands expr)))))))
  (expr-constp-value expr))

(defun expr-alternatives (expr)
  (when (null (expr-alternatives-value expr))
    (format t "alternativing ~A~%" expr)
    (setf (expr-alternatives-value expr)
	  (if (or (expr-constp expr) (expr-expanded-transformation-p expr))
	      (list expr)
	      (cons expr (mapcar* #'(lambda (transformation)
				      (apply-transformation transformation expr))
				  *transformations*)))))
  (expr-alternatives-value expr))

(defun one-sequences (bits &optional (start 0))
  (let ((begin (position 1 bits :start start)))
    (if (null begin)
	nil
	(let ((end (position 0 bits :start (1+ begin))))
	  (if (null end)
	      (list (cons begin (1- (length bits))))
	      (cons (cons begin (1- end)) (one-sequences bits (1+ end))))))))

(defun common-known-bits (insns used-bits)
  (let ((bits (bit-not used-bits)))
    (dolist (insn insns)
      (bit-and bits (insn-known-bits insn) bits))
    (one-sequences bits)))

(defun build-decision-tree (insns &optional (used-bits (make-array (machine-insn-bits *this-machine*) :element-type 'bit :initial-element 0)))
  (labels ((build-tree (insns used-bits)
	     (cond ((null insns)
		    (error "no insns~%"))
		   ((null (cdr insns))
		    (car insns))
		   (t
		    (let* ((common (sort (common-known-bits insns used-bits)
					 #'(lambda (a b)
					     (> (- (cdr a) (car a))
						(- (cdr b) (car b))))))
			   (discriminator (car common)))
		      (when (null discriminator)
			(error "cannot discriminate between insns ~A~%" insns))
		      (cons discriminator (discriminate insns discriminator used-bits))))))
	   (value-at-discriminator (insn discriminator)
	     (let ((begin (car discriminator))
		   (end (cdr discriminator))
		   (value 0))
	       (dofromto (i begin end)
		 (when (= (bit (insn-known-bit-values insn) i) 1)
		   (incf value (expt 2 (- i begin)))))
	       value))
	   (discriminate (insns discriminator used-bits)
	     (if (null insns)
		 nil
		 (let* ((value (value-at-discriminator (car insns) discriminator))
			(matching-insns (remove-if-not #'(lambda (insn)
							   (= (value-at-discriminator insn discriminator) value))
						       insns))
			(rest-insns (remove-if #'(lambda (insn)
						   (= (value-at-discriminator insn discriminator) value))
					       insns)))
		   (cons (cons value (build-tree matching-insns
						 (bit-ior used-bits (bit-range (car discriminator) (cdr discriminator)))))
			 (discriminate rest-insns discriminator used-bits))))))
    (build-tree insns used-bits)))

(defun code-for-field (expr begin end)
  (let ((width (1+ (- end begin))))
    (format nil "((~A >> ~A) & 0x~X)" expr begin (1- (expt 2 width)))))

(defun make-tmp-name ()
  (let ((name (format nil "tmp_~A" *tmp-num*)))
    (incf *tmp-num*)
    name))

(defun c-type (width type &optional (signed nil))
  (case type
    (integer
     (if signed
	 (format nil "sword_~A" width)
	 (format nil "word_~A" width)))
    (float
     (case width
       (32 "float")
       (64 "double")
       (t (error "no float type with width ~A~%" width))))
    (t
     (error "no type ~A~%" type))))

(defun fields-in-expr (expr)
  (cond ((consp expr)
	 (union (fields-in-expr (car expr)) (fields-in-expr (cdr expr))))
	((expr-p expr)
	 (if (eq (expr-kind expr) 'field)
	     (list (first (expr-operands expr)))
	     (fields-in-expr (expr-operands expr))))
	(t
	 nil)))

(defun make-integer-expr (width value)
  (make-expr :kind 'integer :type 'integer :width width :operands (list value)))

(defun register-number-expr (reg)
  (make-integer-expr (register-class-number-width (register-register-class reg))
		     (register-number reg)))

(defun generate-expr (expr &optional (bindings nil) (required-width nil) (required-type 'integer))
  (labels ((match-width (width)
	     (when (and (not (null required-width))
			(/= width required-width))
	       (error "width ~A should be ~A in ~A~%" width required-width expr)))
	   (match-type (type)
	     (when (and (not (null required-type))
			(not (eq required-type type)))
	       (error "type ~A should be ~A in ~A~%" type required-type expr)))
	   (resolve-register (name-or-field class-name)
	     (cond ((register-class-p class-name)
		    (values name-or-field class-name (register-number-expr name-or-field)))
		   ((registerp name-or-field)
		    (let* ((register (lookup-register name-or-field))
			   (class (register-register-class register)))
		      (values register class (register-number-expr register))))
		   (t
		    (let ((class (lookup-register-class class-name)))
		      (when (null class)
			(error "unknown register class in ~A~%" expr))
		      (values nil class (generate-expr name-or-field bindings))))))
	   (resolve-toplevel-bindings (expr)
	     (if (listp expr)
		 (cons (car expr) (mapcar #'(lambda (x)
					      (cond ((symbolp x)
						     (let ((binding (cdr (assoc x bindings))))
						       (if (and binding *expand-transformation*)
							   binding
							   x)))
						    ((and (consp x) (eq (car x) 'eval))
						     (progv (mapcar #'car bindings) (mapcar #'cdr bindings)
						       (eval (second x))))
						    (t
						     x)))
					  (cdr expr)))
		 expr))
	   (generate ()
	     (let ((expr (resolve-toplevel-bindings expr)))
	       (cond ((expr-p expr)
		      expr)
		     ((fieldp expr)
		      (multiple-value-bind (begin end expr)
			  (lookup-field expr)
			expr))
		     ((registerp expr)
		      (let* ((register (lookup-register expr))
			     (register-class (register-register-class register))
			     (width (register-class-width register-class))
			     (type (register-class-type register-class)))
			(make-expr :kind 'register :type type :width width :operands (list register nil nil))))
		     ((subregisterp expr)
		      (let* ((subregister (lookup-subregister expr))
			     (register (subregister-register subregister))
			     (begin (subregister-begin subregister))
			     (end (subregister-end subregister))
			     (width (1+ (- end begin)))
			     (class (register-register-class register))
			     (type (register-class-type class)))
			(make-expr :kind 'subregister :type type :width width
				   :operands (list register class (register-number-expr register) begin end t))))
		     ((integerp expr)
		      (make-expr :kind 'integer :type 'integer :width (or required-width (machine-word-bits *this-machine*)) :operands (list expr)))
		     ((floatp expr)
		      (make-expr :kind 'float :type 'float :width (or required-width (machine-double-bits *this-machine*)) :operands (list expr)))
		     ((stringp expr)
		      (make-expr :kind 'string :type 'string :width nil :operands (list expr)))
		     ((eq expr 'pc)
		      (make-expr :kind 'pc :type 'integer :width (machine-word-bits *this-machine*)))
		     ((eq expr 'addr)
		      (make-expr :kind 'addr :type 'integer :width (machine-word-bits *this-machine*)))
		     ((symbolp expr)
		      (let ((binding (cdr (assoc expr bindings))))
			(if (null binding)
			    (error "unknown variable ~A~%" expr)
			    (if *expand-transformation*
				binding
				(make-expr :kind 'symbol :type (expr-type binding) :width (expr-width binding) :operands (list expr))))))
		     ((consp expr)
		      (case (first expr)
			(ignore
			 (unless (and (null required-width)
				      (null required-type))
			   (error "ignore has no return value~%"))
			 (make-expr :kind 'ignore :operands (list (generate-expr (second expr) bindings))))
			(widen
			 (let ((op (generate-expr (second expr) bindings))
			       (*expand-transformation* nil))
			   (64bitify op)))
			(let
			    (unless (and (null required-width)
					 (null required-type))
			      (error "let has no return value~%"))
			  (let ((new-bindings (mapcar #'(lambda (binding)
							  (destructuring-bind (name value)
							      binding
							    (let ((expr (generate-expr value bindings nil nil)))
							      (cons name expr))))
						      (second expr))))
			    (make-expr :kind 'let :type nil :width nil
				       :operands (list new-bindings (mapcar #'(lambda (expr)
										(generate-expr expr (append new-bindings bindings)
											       nil nil))
									    (cddr expr))))))
			(set
			 (unless (and (null required-width)
				      (null required-type))
			   (error "set has no return value~%"))
			 (let ((lvalue (resolve-toplevel-bindings (second expr))))
			   (cond ((subregisterp lvalue)
				  (let* ((subregister (lookup-subregister lvalue))
					 (begin (subregister-begin subregister))
					 (end (subregister-end subregister))
					 (width (1+ (- end begin))))
				    (make-expr :kind 'set
					       :operands (list (make-expr :kind 'subregister :type 'integer :width width
									  :operands (list subregister))
							       (generate-expr (third expr) bindings width 'integer)))))
				 (t
				  (case (first lvalue)
				    (reg
				     (multiple-value-bind (register class number)
					 (resolve-register (second lvalue) (third lvalue))
				       (let ((type (register-class-type class))
					     (width (register-class-width class)))
					 (make-expr :kind 'set
						    :operands (list (make-expr :kind 'register :type type :width width
									       :operands (list register class number))
								    (generate-expr (third expr) bindings width type))))))
				    (target-register
				     (let* ((register (second lvalue))
					    (class (third lvalue))
					    (type (register-class-type class))
					    (width (register-class-width class)))
				       (make-expr :kind 'set
						  :operands (list (make-expr :kind 'target-register :type type :width width
									     :operands (list register class))
								  (generate-expr (third expr) bindings width type)))))
				    (numbered-subreg
				     (let ((width (second lvalue)))
				       (multiple-value-bind (register class number)
					   (resolve-register (fourth lvalue) (fifth lvalue))
					 (unless (eq (register-class-type class) 'integer)
					   (error "numbered subregisters are only allowed of integer registers: ~A~%" expr))
					 (let ((index (generate-expr (third lvalue) bindings)))
					   (make-expr :kind 'set
						      :operands (list (make-expr :kind 'numbered-subregister :type 'integer :width width
										 :operands (list register class number width index))
								      (generate-expr (third expr) bindings width)))))))
				    (mem
				     (let ((width (or (third lvalue) (machine-word-bits *this-machine*))))
				       (make-expr :kind 'set
						  :operands (list (make-expr :kind 'mem :type 'integer :width width
									     :operands (list width
											     (generate-expr (second lvalue) bindings
													    (machine-word-bits *this-machine*))))
								  (generate-expr (third expr) bindings width)))))
				    (t
				     (error "not an lvalue: ~A~%" lvalue)))))))
			(width
			 (let ((width (second expr)))
			   (generate-expr (third expr) bindings width (or required-type 'integer))))
			(promote
			 (let ((width (second expr))
			       (value (generate-expr (third expr) bindings)))
			   (make-expr :kind 'promote :type 'integer :width width :operands (list value))))
			(jump-relative
			 (unless (and (null required-width)
				      (null required-type))
			   (error "jump-relative has no return value~%"))
			 (let ((offset (generate-expr (second expr) bindings (machine-word-bits *this-machine*))))
			   (make-expr :kind 'jump
				      :operands (list (make-expr :kind '+ :type 'integer :width (machine-word-bits *this-machine*)
								 :operands (list (make-expr :kind 'pc) offset))))))
			(jump-absolute
			 (unless (and (null required-width)
				      (null required-type))
			   (error "jump-absolute has no return value~%"))
			 (make-expr :kind 'jump
				    :operands (list (generate-expr (second expr) bindings (machine-word-bits *this-machine*)))))
			(if
			 (let ((cond (generate-expr (second expr) bindings))
			       (cons (generate-expr (third expr) bindings required-width required-type))
			       (alt (generate-expr (fourth expr) bindings required-width required-type)))
			   (unless (and (eql (expr-width cons) (expr-width alt))
					(eq (expr-type cons) (expr-type alt)))
			     (error "widths and/or types do not match in ~A~%" expr))
			   (when (and (not (null required-width))
				      (null (expr-width cons)))
			     (error "width should be ~A in ~A~%" required-width expr))
			   (when (and (not (null required-type))
				      (null (expr-type cons)))
			     (error "type should be ~A in ~A~%" required-type expr))
			   (make-expr :kind 'if :type (expr-type cons) :width (expr-width cons)
				      :operands (list cond cons alt))))
			((= =f < <s <f <= <=s <=f > >s >f >= >=s >=f)
			 (let* ((op-type (if (member (first expr) '(=f <f <=f >f >=f)) 'float 'integer))
				(op1 (generate-expr (second expr) bindings nil op-type))
				(op2 (generate-expr (third expr) bindings nil op-type)))
			   (when (/= (expr-width op1) (expr-width op2))
			     (error "widths do not match in ~A~%" expr))
			   (make-expr :kind (first expr) :type 'integer :width (machine-word-bits *this-machine*) :operands (list op1 op2))))
			(bit-set-p
			 (let ((value (generate-expr (second expr) bindings))
			       (bit (generate-expr (third expr) bindings)))
			   (make-expr :kind 'bit-set-p :type 'integer :width (machine-word-bits *this-machine*)
				      :operands (list value bit))))
			(reg
			 (multiple-value-bind (register class number)
			     (resolve-register (second expr) (third expr))
			   (let ((type (register-class-type class))
				 (width (register-class-width class)))
			     (make-expr :kind 'register :type type :width width :operands (list register class number)))))
			(subreg
			 (let* ((begin (second expr))
				(end (third expr))
				(width (1+ (- end begin))))
			   (multiple-value-bind (register class number)
			       (resolve-register (fourth expr) (fifth expr))
			     (unless (eq (register-class-type class) 'integer)
			       (error "only subregisters of integer registers are allowed: ~A~%" expr))
			     (make-expr :kind 'subregister :type 'integer :width width
					:operands (list register class number begin end nil)))))
			(numbered-subreg
			 (let ((width (second expr)))
			   (multiple-value-bind (register class number)
			       (resolve-register (fourth expr) (fifth expr))
			     (unless (eq (register-class-type class) 'integer)
			       (error "only numbered subregisters of integer registers are allowed: ~A~%" expr))
			     (make-expr :kind 'numbered-subregister :type 'integer :width width
					:operands (list register class number width (generate-expr (third expr) bindings))))))
			(mem
			 (when (null required-width)
			   (error "no required width in ~A~%" expr))
			 (make-expr :kind 'mem :type 'integer :width (or required-width (machine-word-bits *this-machine*))
				    :operands (list (generate-expr (second expr) bindings (machine-word-bits *this-machine*)))))
			((zex sex)
			 (when (null required-width)
			   (error "no required width in ~A~%" expr))
			 (let ((op (generate-expr (second expr) bindings)))
			   (make-expr :kind (first expr) :type 'integer :width required-width :operands (list op))))
			((+ - * *s / /s logor logand logxor)
			 (let ((op1 (generate-expr (second expr) bindings required-width))
			       (op2 (generate-expr (third expr) bindings required-width)))
			   (when (/= (expr-width op1) (expr-width op2))
			     (error "widths do not match in ~A" expr))
			   (make-expr :kind (first expr) :type 'integer :width (expr-width op1)
				      :operands (list op1 op2))))
			((+f -f *f /f)
			 (let ((op1 (generate-expr (second expr) bindings required-width 'float))
			       (op2 (generate-expr (third expr) bindings required-width 'float)))
			   (when (/= (expr-width op1) (expr-width op2))
			     (error "widths do not match in ~A" expr))
			   (make-expr :kind (first expr) :type 'float :width (expr-width op1)
				      :operands (list op1 op2))))
			(+carry
			 (let ((op1 (generate-expr (second expr) bindings (machine-word-bits *this-machine*)))
			       (op2 (generate-expr (third expr) bindings (machine-word-bits *this-machine*))))
			   (make-expr :kind '+carry :type 'integer :width 1
				      :operands (list op1 op2))))
			((neg bitneg not)
			 (let ((op (generate-expr (second expr) bindings (machine-word-bits *this-machine*))))
			   (make-expr :kind (first expr) :type 'integer :width (machine-word-bits *this-machine*)
				      :operands (list op))))
			((fneg sqrt)
			 (let* ((op (generate-expr (second expr) bindings required-width 'float))
				(width (expr-width op)))
			   (make-expr :kind (first expr) :type 'float :width width :operands (list op))))
			((shiftl shiftr rotl)
			 (let* ((op1 (generate-expr (second expr) bindings required-width))
				(op2 (generate-expr (third expr) bindings))
				(width (expr-width op1)))
			   (make-expr :kind (first expr) :type 'integer :width width
				      :operands (list op1 op2))))
			(ashiftr
			 (let ((op1 (generate-expr (second expr) bindings (machine-word-bits *this-machine*)))
			       (op2 (generate-expr (third expr) bindings)))
			   (make-expr :kind 'ashiftr :type 'integer :width (machine-word-bits *this-machine*)
				      :operands (list op1 op2))))
			(mask
			 (let ((op1 (generate-expr (second expr) bindings))
			       (op2 (generate-expr (third expr) bindings)))
			   (make-expr :kind 'mask :type 'integer :width (or required-width (machine-word-bits *this-machine*))
				      :operands (list op1 op2))))
			(maskmask
			 (let* ((bit-width (second expr))
				(mask (generate-expr (third expr) bindings))
				(mask-width (expr-width mask))
				(width (* bit-width mask-width)))
			   (make-expr :kind 'maskmask :type 'integer :width width
				      :operands (list bit-width mask))))
			((leading-zeros trailing-zeros population)
			 (let ((op (generate-expr (second expr) bindings (machine-word-bits *this-machine*))))
			   (make-expr :kind (first expr) :type 'integer :width (or required-width (machine-word-bits *this-machine*))
				      :operands (list op))))
			((single-to-double double-to-single)
			 (multiple-value-bind (old-width new-width)
			     (if (eq (first expr) 'single-to-double)
				 (values (machine-single-bits *this-machine*) (machine-double-bits *this-machine*))
				 (values (machine-double-bits *this-machine*) (machine-single-bits *this-machine*)))
			   (let ((value (generate-expr (second expr) bindings old-width 'float)))
			     (make-expr :kind 'convert-float :type 'float :width new-width
					:operands (list value)))))
			((bits-to-single bits-to-double)
			 (let* ((width (if (eq (first expr) 'bits-to-single) (machine-single-bits *this-machine*) (machine-double-bits *this-machine*)))
				(value (generate-expr (second expr) bindings width 'integer)))
			   (make-expr :kind 'bits-to-float :type 'float :width width
				      :operands (list value))))
			((single-to-bits double-to-bits)
			 (let* ((width (if (eq (first expr) 'single-to-bits) (machine-single-bits *this-machine*) (machine-double-bits *this-machine*)))
				(value (generate-expr (second expr) bindings width 'float)))
			   (make-expr :kind 'float-to-bits :type 'integer :width width
				      :operands (list value))))
			((single-to-integer double-to-integer)
			 (let* ((float-width (if (eq (first expr) 'single-to-integer)
						 (machine-single-bits *this-machine*)
						 (machine-double-bits *this-machine*)))
				(integer-width (or required-width (machine-word-bits *this-machine*)))
				(value (generate-expr (second expr) bindings float-width 'float)))
			   (make-expr :kind 'float-to-integer :type 'integer :width integer-width
				      :operands (list value))))
			((integer-to-single integer-to-double)
			 (let* ((integer-width (or required-width (machine-word-bits *this-machine*)))
				(float-width (if (eq (first expr) 'integer-to-single)
						 (machine-single-bits *this-machine*)
						 (machine-double-bits *this-machine*)))
				(value (generate-expr (second expr) bindings integer-width 'integer)))
			   (make-expr :kind 'integer-to-float :type 'float :width float-width
				      :operands (list value))))
			(nop
			 (make-expr :kind 'nop))
			(syscall
			 (make-expr :kind 'system-call))
			(call-pal
			 (let ((value (generate-expr (second expr) bindings (machine-word-bits *this-machine*))))
			   (make-expr :kind 'call-pal :operands (list value))))
			(not-implemented
			 (make-expr :kind 'not-implemented))
			(t
			 (error "unknown pattern ~A~%" (first expr)))))
		     (t
		      (error "illegal expr ~A~%" expr))))))
    (let ((result (generate)))
      (match-type (expr-type result))
      (match-width (expr-width result))
      result)))

(defun generate-interpreter (expr bindings)
  (labels ((register-code (reg &optional class number (with-parens t))
	     (format nil "~:[~;(~]intp->regs_~A[~A]~:[~;)~]"
		     with-parens
		     (register-class-name class)
		     (generate-interpreter number bindings)
		     with-parens)))
    (expr-case expr
      (field (name begin end)
	     (if *take-fields-from-variables*
		 (format nil "field_~A" (dcs name))
		 (code-for-field "insn" begin end)))
      (integer (value) (format nil "~A" value))
      (string (value) (format nil "\"~A\"" value))
      (pc () "pc")
      (addr () "addr")
      (symbol (name) (cdr (assoc name bindings)))
      (input (name) name)
      (ignore (value) "0 /* ignore */")
      (let (let-bindings body)
	   (with-output-to-string (out)
	     (format out "{~%")
	     (let ((new-bindings (append (mapcar #'(lambda (binding)
						     (destructuring-bind (name . expr)
							 binding
						       (let ((code (generate-interpreter expr bindings))
							     (c-name (make-tmp-name)))
							 (format out "~A ~A = ~A;~%"
								 (c-type (expr-width expr) (expr-type expr)) c-name code)
							 (cons name c-name))))
						 let-bindings)
					 bindings)))
	       (dolist (expr body)
		 (format out "~A;~%" (generate-interpreter expr new-bindings))))
	     (format out "}~%")))
      (set (lvalue rhs)
	   (expr-case lvalue
	     (register (reg class number)
		       (format nil "(~A = ~A)" (register-code reg class number) (generate-interpreter rhs bindings)))
	     (subregister (subreg)
			  (let* ((reg (subregister-register subreg))
				 (class (register-register-class reg))
				 (reg-code (register-code reg class (register-number-expr reg) nil))
				 (begin (subregister-begin subreg))
				 (end (subregister-end subreg))
				 (width (1+ (- end begin))))
			    (format nil "(~A = (~A & 0x~X) | (~A << ~A))"
				    reg-code
				    reg-code (bit-vector-to-integer (bit-not (bit-range begin end (register-class-width class))))
				    (generate-interpreter rhs bindings) begin)))
	     (numbered-subregister (reg class number width index)
				   (let ((reg-code (register-code reg class number))
					 (index-code (generate-interpreter index bindings)))
				     (format nil "(~A = (~A & ~~mask(~A * ~A, ~A * ~A + ~A - 1)) | (~A << (~A * ~A)))"
					     reg-code
					     reg-code width index-code width index-code width
					     (generate-interpreter rhs bindings) width index-code)))
	     (mem (width addr)
		  (format nil "mem_set_~A(intp, ~A, ~A)" width (generate-interpreter addr bindings)
			  (generate-interpreter rhs bindings)))))
      (promote (value)
	       (format nil "((~A)~A)" (c-type (expr-width expr) 'integer) (generate-interpreter value bindings)))
      (jump (target) (format nil "(next_pc = ~A)" (generate-interpreter target bindings)))
      (if (cond cons alt)
	  (format nil "(~A ? ~A : ~A)"
		  (generate-interpreter cond bindings) (generate-interpreter cons bindings)
		  (generate-interpreter alt bindings)))
      (bit-set-p (value index)
		 (format nil "(~A & (1 << ~A))" (generate-interpreter value bindings) (generate-interpreter index bindings)))
      (register (reg class number) (register-code reg class number))
      (subregister (reg class number begin end named)
		   (let ((width (1+ (- end begin)))
			 (reg-code (register-code reg class number (not named))))
		     (format nil "((~A >> ~A) & 0x~X)" reg-code begin (1- (expt 2 width)))))
      (numbered-subregister (reg class number width index)
			    (let ((reg-code (register-code reg class number)))
			      (format nil "((~A >> (~A * ~A)) & 0x~X)"
				      reg-code width (generate-interpreter index bindings)
				      (1- (expt 2 width)))))
      (mem (addr) (format nil "mem_get_~A(intp, ~A)" (expr-width expr) (generate-interpreter addr bindings)))
      (zex (value) (generate-interpreter value bindings))
      (sex (value)
	   (let ((old-width (expr-width value))
		 (new-width (expr-width expr))
		 (code (generate-interpreter value bindings)))
	     (format nil "((~A & 0x~X) ? (~A | 0x~X) : ~A)"
		     code (expt 2 (1- old-width))
		     code (- (1- (expt 2 new-width)) (1- (expt 2 old-width)))
		     code)))
      (ashiftr (value amount)
	       (let ((value-code (generate-interpreter value bindings))
		     (amount-code (generate-interpreter amount bindings)))
		 (format nil "((~A >> ~A) | ((~A & 0x80000000) ? ~~((1 << (32 - ~A)) - 1) : 0))"
			 value-code amount-code value-code amount-code)))
      (maskmask (bit-width mask)
		(format nil "maskmask(~A, ~A, ~A)" bit-width (expr-width mask) (generate-interpreter mask bindings)))
      (leading-zeros (value) (format nil "leading_zeros(~A)" (generate-interpreter value bindings)))
      (convert-float (value)
		     (format nil "((~A)~A)" (c-type (expr-width expr) 'float) (generate-interpreter value bindings)))
      (bits-to-float (value)
		     (let ((width (expr-width expr)))
		       (format nil "({ ~A tmp = ~A; *(~A*)&tmp; })"
			       (c-type width 'integer)
			       (generate-interpreter value bindings)
			       (c-type width 'float))))
      (float-to-bits (value)
		     (let ((width (expr-width expr)))
		       (format nil "({ ~A tmp = ~A; *(~A*)&tmp; })"
			       (c-type width 'float)
			       (generate-interpreter value bindings)
			       (c-type width 'integer))))
      (float-to-integer (value)
			(let ((width (expr-width expr)))
			  (format nil "((~A)(~A)~A)" (c-type width 'integer) (c-type width 'integer t)
				  (generate-interpreter value bindings))))
      (nop () "0 /* nop */")
      (system-call () "handle_system_call(intp)")
      ((= < <f > >f + +f - -f * *f / /f logor logand logxor shiftl shiftr) (left right)
       (let ((op (cadr (assoc (expr-kind expr) '((= "==") (< "<") (<f "<") (> ">") (>f ">") (+ "+") (+f "+") (- "-")
						 (-f "-") (* "*") (*f "*") (/ "/") (/f "/")
						 (logor "|") (logand "&") (logxor "^") (shiftl "<<") (shiftr ">>"))))))
	 (format nil "(~A ~A ~A)" (generate-interpreter left bindings) op (generate-interpreter right bindings))))
      ((*s /s) (left right)
       (let* ((op (cadr (assoc (expr-kind expr) '((*s "*") (/s "/")))))
	      (width (expr-width expr))
	      (type (c-type width 'integer t)))
	 (format nil "((~A)((~A)~A ~A (~A)~A))"
		 (c-type width 'integer)
		 type (generate-interpreter left bindings) op type (generate-interpreter right bindings))))
      ((neg fneg bitneg not) (value)
       (let ((op (cadr (assoc (expr-kind expr) '((neg "-") (fneg "-") (bitneg "~") (not "!"))))))
	 (format nil "(~A~A)" op (generate-interpreter value bindings))))
      ((<s >s) (left right)
       (let ((op (cadr (assoc (expr-kind expr) '((<s "<") (>s ">")))))
	     (type (c-type (expr-width left) 'integer t)))
	 (format nil "((~A)~A ~A (~A)~A)"
		 type (generate-interpreter left bindings) op
		 type (generate-interpreter right bindings))))
      ((+carry -carry rotl mask) (first second)
       (let ((func (cadr (assoc (expr-kind expr) '((+carry "addcarry") (-carry "subcarry") (rotl "rotl") (mask "mask"))))))
	 (format nil "~A(~A, ~A)" func (generate-interpreter first bindings) (generate-interpreter second bindings)))))))

(defun expr-equal-p (e1 e2)
  (or (eq e1 e2)
      (and (eq (expr-kind e1) (expr-kind e2))
	   (eq (expr-type e1) (expr-type e2))
	   (eq (expr-width e1) (expr-width e2))
	   (every #'(lambda (a b)
		      (if (and (expr-p a) (expr-p b))
			  (expr-equal-p a b)
			  (eq a b)))
		  (expr-operands e1) (expr-operands e2)))))

(defun simplify (expr)
  (let* ((operands (mapcar #'(lambda (x) (if (expr-p x) (simplify x) x)) (expr-operands expr)))
	 (expr (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr) :operands operands)))
    (expr-case expr
      ((+ logor) (op1 op2)
	 (cond ((and (eq (expr-kind op1) 'integer) (= (first (expr-operands op1)) 0))
		op2)
	       ((and (eq (expr-kind op2) 'integer) (= (first (expr-operands op2)) 0))
		op1)
	       (t
		expr)))
      (mask (begin end)
	    (if (and (eq (expr-kind begin) 'integer) (eq (expr-kind end) 'integer))
		(make-integer-expr (expr-width expr) (mask (first (expr-operands begin)) (first (expr-operands end)) (expr-width expr)))
		expr))
      (t
       expr))))

(defun apply-transformation (trans expr)
  (multiple-value-bind (success bindings)
      (match-sexpr (transformation-pattern trans) expr)
    (if success
	(let ((*expand-transformation* t)
	      (*this-machine* *target-machine*))
	  (generate-expr (transformation-substitution trans) bindings (expr-width expr) (expr-type expr)))
	nil)))

(defun match-generator (expr generator)
  (labels ((matches-constraints-p (expr constraints)
	     (destructuring-bind (type (rel width) source)
		 constraints
	       (and (eq type (expr-type expr))
		    (or (and (eq rel '=) (= (expr-width expr) width))
			(and (eq rel '<=) (<= (expr-width expr) width)))
		    (or (eq source 'reg)
			(and (eq source 'const) (expr-constp expr))))))
	   (bind (name expr bindings)
	     (let ((binding (cdr (assoc name bindings))))
	       (if binding
		   (if (expr-equal-p expr binding)
		       (values t bindings)
		       (values nil (list 'inconsistent-values name)))
		   (let ((constraints (cdr (assoc name (generator-inputs generator)))))
		     (if (matches-constraints-p expr constraints)
			 (values t (acons name expr bindings))
			 (values nil (list 'does-not-match-constraints expr constraints)))))))
	   (match-multiple (exprs patterns bindings)
;	     (format t "matching multiple ~A with ~A bindings ~A~%" exprs patterns bindings)
	     (if (null exprs)
		 (values t bindings)
		 (multiple-value-bind (success new-bindings)
		     (match (car exprs) (car patterns) bindings)
		   (if success
		       (match-multiple (cdr exprs) (cdr patterns) new-bindings)
		       (values nil new-bindings)))))
	   (match (expr pattern bindings)
	     (cond ((symbolp pattern)
		    (bind pattern expr bindings))
		   ((integerp pattern)
		    (if (and (expr-constp expr) (eq (expr-type expr) 'integer))
			(values t (acons pattern expr bindings))
			(values nil (list 'invalid-integer pattern expr))))
		   ((consp pattern)
		    (case (first pattern)
		      (set
		       (if (eq (expr-kind expr) 'set)
			   (destructuring-bind (lvalue rhs)
			       (expr-operands expr)
			     (case (first (second pattern))
			       (mem
				(if (eq (expr-kind lvalue) 'mem)
				    (destructuring-bind (width address)
					(expr-operands lvalue)
				      (if (= width (third (second pattern)))
					  (match-multiple (list address rhs)
							  (list (second (second pattern))
								(third pattern))
							  bindings)
					  (values nil 'set-mem-widths-do-not-match expr)))
				    (values nil 'set-expr-type-not-set-mem expr)))
			       (t
				(error "set ~A not supported~%" expr))))
			   (values nil 'expr-type-not-set expr)))
		      (mem
		       (if (eq (expr-kind expr) 'mem)
			   (if (= (expr-width expr) (third pattern))
			       (match (first (expr-operands expr)) (second pattern) bindings)
			       (values nil 'mem-widths-do-not-match expr))
			   (values nil 'expr-not-mem expr)))
		      ((if <s >s + sex)
		       (if (eq (expr-kind expr) (first pattern))
			   (match-multiple (expr-operands expr) (rest pattern) bindings)
			   (values nil (list 'wrong-expr-type (first pattern) expr))))
		      (t
		       (error "unknown pattern ~A~%" (first pattern)))))
		   (t
		    (error "illegal pattern ~A~%" pattern)))))
    (if (and (eq (second (generator-result generator)) (expr-type expr))
	     (eq (third (generator-result generator)) (expr-width expr)))
	(match expr (generator-pattern generator) nil)
	nil)))

(defun find-generator (expr generators)
  (if (null generators)
      nil
      (multiple-value-bind (success bindings)
	  (match-generator expr (car generators))
	(if success
	    (values (car generators) bindings)
	    (find-generator expr (cdr generators))))))

(defun register-index (reg class number)
  (if reg
      (+ (register-number reg) (register-class-start-index class))
      (format nil "(~A + ~A)" (register-class-start-index class) (generate-interpreter number nil))))

(defun contains-jump-p (expr)
  (cond ((consp expr)
	 (or (contains-jump-p (car expr)) (contains-jump-p (cdr expr))))
	((expr-p expr)
	 (or (eq (expr-kind expr) 'jump)
	     (contains-jump-p (expr-operands expr))))
	(t
	 nil)))

(defun generate-compiler (target expr bindings &key true-label false-label (foreign-target -1))
  (labels ((load-reg-name (type width)
	     (format nil "load_reg_~A_~A" (dcs type) width))
	   (store-reg-name (type width)
	     (format nil "store_reg_~A_~A" (dcs type) width)))
    (cond ((expr-constp expr)
	   (unless (eq (expr-type expr) 'integer)
	     (error "can only load integers~%"))
	   (let* ((width (expr-width expr))
		  (load-width (if (<= width 32) 32 width)))
	     (format nil "~A = ref_integer_reg_for_writing(~A);
emit_load_integer_~A(~A, ~A);~%"
		     target foreign-target
		     load-width target (generate-interpreter expr nil))))
	  (t
	   (multiple-value-bind (generator gen-bindings)
	       (find-generator expr (machine-generators *this-machine*))
	     (if generator
		 (format nil "if (~A)
{
~A}
else
{
~A}~%"
			 (reduce #'(lambda (a b)
				     (format nil "~A && ~A" a b)) 
				 (mapcar #'(lambda (gen-binding)
					     (destructuring-bind (name . bound-expr)
						 gen-binding
					       (if (integerp name)
						   (format nil "~A == ~A"
							   (generate-interpreter bound-expr nil) name)
						   "1")))
					 gen-bindings)
				 :initial-value "1")
			 (let ((c-bindings (mapcar* #'(lambda (gen-binding)
							(destructuring-bind (name . bound-expr)
							    gen-binding
							  (if (symbolp name)
							      (destructuring-bind (type (rel width) source)
								  (cdr (assoc name (generator-inputs generator)))
								(let ((c-name (make-tmp-name)))
								  (list name
									(if (eq source 'const)
									    (c-type width type)
									    "reg_t")
									c-name source bound-expr
									(if (eq source 'const)
									    (generate-interpreter bound-expr nil)
									    "0")
									(if (eq source 'const)
									    nil
									    (format nil "unref_~A_reg(~A)" (dcs type) c-name)))))
							      nil)))
						    gen-bindings)))
			   (format nil "~{~A ~A = ~A;~^
~}
~{~A~}
~A
~{~A;~^
~}
~{~A;~^
~}~%"
				   (mappend #'(lambda (b) (list (second b) (third b) (sixth b))) c-bindings)
				   (mapcar* #'(lambda (b)
						(if (eq (fourth b) 'reg)
						    (generate-compiler (third b) (fifth b) bindings)
						    nil))
					    c-bindings)
				   (if target
				       (format nil "~A = ref_~A_reg_for_writing(~A);" target (dcs (expr-type expr)) foreign-target)
				       "")
				   (mapcar #'(lambda (i)
					       (format nil "emit(COMPOSE_~A(~{~A~^, ~}))"
						       (first i)
						       (mapcar #'(lambda (n)
								   (if (eq n (first (generator-result generator)))
								       target
								       (third (assoc n c-bindings))))
							       (rest i))))
					   (generator-code generator))
				   (mapcar* #'(lambda (b) (seventh b)) c-bindings)))
			 default-generator)
		 (expr-case expr
		   (field (name begin end)
			  (format nil "~A = ref_integer_reg_for_writing(~A);
emit_load_integer_32(~A, ~A);~%"
				  target foreign-target
				  target (code-for-field "insn" begin end)))
		   (string (value) (error "cannot generate compiler for string~%"))
		   (pc () (format nil "~A = ref_integer_reg_for_writing(~A);
emit_load_integer_32(~A, pc);~%"
						    target foreign-target
						    target))
		   (addr () (error "cannot generate compiler for addr~%"))
		   (symbol (name)
			   (let ((value (cdr (assoc name bindings))))
			     (format nil "~A = ref_integer_reg_for_writing(~A);~%~A~%"
				     target foreign-target
				     (if (expr-constp expr)
					 (format nil "emit_load_integer_32(~A, ~A);~%" target value)
					 (format nil "emit(COMPOSE_MOV(~A, ~A));~%" value target)))))
		   (let (let-bindings body)
		        (with-output-to-string (out)
			  (format out "{~%")
			  (let* ((new-bindings (mapcar #'(lambda (binding)
							   (destructuring-bind (name . expr)
							       binding
							     (let ((c-name (make-tmp-name)))
							       (if (expr-constp expr)
								   (let ((code (generate-interpreter expr bindings)))
								     (format out "~A ~A = ~A;~%"
									     (c-type (expr-width expr) (expr-type expr)) c-name code))
								   (format out "reg_t ~A = ref_~A_reg_for_writing(-1);
~A"
									   c-name (dcs (expr-type expr))
									   (generate-compiler c-name expr bindings
											      :foreign-target (format nil
														      "~A | NEED_NATIVE"
														      c-name))))
							       (cons name c-name))))
						       let-bindings))
				 (all-bindings (append new-bindings bindings)))
			    (dolist (expr body)
			      (format out "~A;~%" (generate-compiler nil expr all-bindings)))
			    (mapc #'(lambda (let-binding binding)
				      (format out "unref_~A_reg(~A);~%"
					      (dcs (expr-type (cdr let-binding)))
					      (cdr binding)))
				  let-bindings new-bindings)
			    (format out "}~%"))))
		   (set (lvalue rhs)
			(expr-case lvalue
			  (register (reg class number)
				    (let ((reg-index (register-index reg class number))
					  (type (register-class-type class))
					  (reg-reg (make-tmp-name)))
				      (format nil "{
reg_t ~A;
~Aunref_~A_reg(~A);
}~%"
					      reg-reg
					      (generate-compiler reg-reg rhs bindings :foreign-target reg-index) (dcs type) reg-reg)))
			  (subregister (subreg)
				       (let* ((reg (subregister-register subreg))
					      (class (register-register-class reg))
					      (reg-index (register-index reg class (register-number reg)))
					      (reg-width (register-class-width class))
					      (begin (subregister-begin subreg))
					      (end (subregister-end subreg))
					      (width (1+ (- end begin)))
					      (rhs-reg (make-tmp-name))
					      (mask-reg (make-tmp-name))
					      (reg-reg (make-tmp-name)))
					 (format nil "{
reg_t ~A, ~A, ~A;
~Aemit(COMPOSE_SLL_IMM(~A, ~A, ~A));
emit(COMPOSE_SRL_IMM(~A, ~A, ~A));
~A = ref_integer_reg_for_writing(-1);
emit_load_integer_32(~A, -1);
emit(COMPOSE_SLL_IMM(~A, ~A, ~A));
emit(COMPOSE_SRL_IMM(~A, ~A, ~A));
~A = ref_integer_reg_for_reading_and_writing(~A);
emit(COMPOSE_BIC(~A, ~A, ~A));
unref_integer_reg(~A);
emit(COMPOSE_BIS(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
}~%"
						 rhs-reg mask-reg reg-reg
						 (generate-compiler rhs-reg rhs bindings) rhs-reg (- 64 width) rhs-reg
						 rhs-reg (- 63 end) rhs-reg
						 mask-reg
						 mask-reg
						 mask-reg (- 64 width) mask-reg
						 mask-reg (- 63 end) mask-reg
						 reg-reg reg-index
						 reg-reg mask-reg reg-reg
						 mask-reg
						 reg-reg rhs-reg reg-reg
						 rhs-reg
						 reg-reg)))
			  (numbered-subregister (reg class number width index)
						(let ((reg-index (register-index reg class number))
						      (reg-width (register-class-width class))
						      (rhs-reg (make-tmp-name))
						      (mask-reg (make-tmp-name))
						      (reg-reg (make-tmp-name)))
						  (format nil "{
word_64 begin = ~A * ~A;
reg_t ~A, ~A, ~A;
~Aemit(COMPOSE_SLL_IMM(~A, begin, ~A));
~A = ref_integer_reg_for_writing(-1);
emit_load_integer_32(~A, -1);
emit(COMPOSE_SRL_IMM(~A, ~A, ~A));
emit(COMPOSE_SLL_IMM(~A, begin, ~A));
emit(COMPOSE_AND(~A, ~A, ~A));
~A = ref_integer_reg_for_reading_and_writing(~A);
emit(COMPOSE_BIC(~A, ~A, ~A));
unref_integer_reg(~A);
emit(COMPOSE_BIS(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
}~%"
							  (generate-interpreter index nil) width
							  rhs-reg mask-reg reg-reg
							  (generate-compiler rhs-reg rhs bindings) rhs-reg rhs-reg
							  mask-reg
							  mask-reg
							  mask-reg (- 64 width) mask-reg
							  mask-reg mask-reg
							  rhs-reg mask-reg rhs-reg
							  reg-reg reg-index
							  reg-reg mask-reg reg-reg
							  mask-reg
							  reg-reg rhs-reg reg-reg
							  rhs-reg
							  reg-reg)))
			  (mem (width addr)
			       (let ((addr-reg (make-tmp-name))
				     (rhs-reg (make-tmp-name)))
				 (format nil "{
reg_t ~A, ~A;
~A/* emit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A)); */
~Aemit_store_mem_~A(~A, ~A);
unref_integer_reg(~A);
unref_integer_reg(~A);
}~%"
					 addr-reg rhs-reg
					 (generate-compiler addr-reg addr bindings) addr-reg addr-reg
					 (generate-compiler rhs-reg rhs bindings) width rhs-reg addr-reg
					 addr-reg
					 rhs-reg)))))
		   (promote (value)
			    (let ((src-width (expr-width value))
				  (dst-width (expr-width expr))
				  (target-code (generate-compiler target value bindings :foreign-target foreign-target)))
			      (if (and (= src-width 32) (= dst-width 64))
				  (format nil "~Aemit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A));~%"
					  target-code target target)
				  (progn
				    (unless (and (= src-width 64) (= dst-width 32))
				      (error "cannot promote from ~A to ~A bits~%" src-width dst-width))
				    (format nil "~Aemit(COMPOSE_SLL_IMM(~A, ~A, ~A));
emit(COMPOSE_SRA_IMM(~A, ~A, ~A));~%"
					    target-code target (- src-width dst-width) target
					    target (- src-width dst-width) target)))))
		   (jump (target)
			 (format nil "store_all_foreign_regs();~%~A~%"
				 (if (expr-constp target)
				     (format nil "emit_direct_jump(~A);" (generate-interpreter target nil))
				     (let ((target-reg (make-tmp-name)))
				       (format nil "{
reg_t ~A;
~Aemit_indirect_jump();
}~%"
					       target-reg
					       (generate-compiler target-reg target bindings
								  :foreign-target "JUMP_TARGET_REG | NEED_NATIVE"))))))
		   (if (cond cons alt)
		       (if (expr-constp cond)
			   (format nil "if (~A) {~%~A} else {~%~A}~%"
				   (generate-interpreter cond nil)
				   (generate-compiler target cons bindings :foreign-target foreign-target)
				   (generate-compiler target alt bindings :foreign-target foreign-target))
			   (let* ((result-reg (if (null target) nil (make-tmp-name)))
				  (dummy-foreign-target (if (null target) -1 (format nil "~A | NEED_NATIVE" result-reg)))
				  (true (make-tmp-name))
				  (false (make-tmp-name))
				  (end (make-tmp-name))
				  (can-jump (or (contains-jump-p cons) (contains-jump-p alt))))
			     (format nil "{
label_t ~A = alloc_label(), ~A = alloc_label(), ~A = alloc_label();
~A
~A
~A
emit_label(~A);
push_alloc();
~Apop_alloc();
emit_branch(COMPOSE_BR(31, 0), ~A);
emit_label(~A);
push_alloc();
~Apop_alloc();
emit_label(~A);
free_label(~A);
free_label(~A);
free_label(~A);
~A
}~%"
				     true false end
				     (if (null target) "" (format nil "reg_t ~A;" result-reg))
				     (generate-compiler nil cond bindings :true-label true :false-label false)
				     (if (null target)
					 ""
					 (format nil "~A = ref_~A_reg_for_writing(-1);" result-reg (dcs (expr-type expr))))
				     true
				     (generate-compiler result-reg cons bindings :foreign-target dummy-foreign-target)
				     end
				     false
				     (generate-compiler result-reg alt bindings :foreign-target dummy-foreign-target)
				     end
				     true false end
				     (if (null target)
					 ""
					 (if (eql foreign-target -1)
					     (format nil "~A = ~A;" target result-reg)
					     (format nil "~A = ref_~A_reg_for_writing(~A);
emit(COMPOSE_~AMOV(~A, ~A));
unref_~A_reg(~A);"
						     target (dcs (expr-type expr)) foreign-target
						     (if (eq (expr-type expr) 'float) "F" "") result-reg target
						     (dcs (expr-type expr)) result-reg)))))))
		   (bit-set-p (value index)
			      (let ((value-reg (make-tmp-name))
				    (bit-reg (make-tmp-name)))
				(format nil "{
reg_t ~A, ~A;
~A~A = ref_integer_reg_for_writing(-1);
emit(COMPOSE_SRL_IMM(~A, ~A, ~A));
unref_integer_reg(~A);
emit_branch(COMPOSE_BLBS(~A, 0), ~A);
unref_integer_reg(~A);
emit_branch(COMPOSE_BR(31, 0), ~A);
}~%"
					value-reg bit-reg
					(generate-compiler value-reg value bindings) bit-reg
					value-reg (generate-interpreter index nil) bit-reg
					value-reg
					bit-reg true-label
					bit-reg
					false-label)))
		   (register (reg class number)
			     (let ((reg-index (register-index reg class number))
				   (type (register-class-type class)))
			       (if (eql foreign-target -1)
				   (format nil "~A = ref_~A_reg_for_reading(~A);~%"
					   target (dcs type) reg-index)
				   (let ((tmp-reg (make-tmp-name)))
				     (format nil "{
reg_t ~A = ref_~A_reg_for_reading(~A);
~A = ref_~A_reg_for_writing(~A);
emit(COMPOSE_~AMOV(~A, ~A));
unref_~A_reg(~A);
}~%"
					     tmp-reg (dcs type) reg-index
					     target (dcs type) foreign-target
					     (if (eq type 'float) "F" "") tmp-reg target
					     (dcs type) tmp-reg)))))
		   (subregister (reg class number begin end named)
				(let ((reg-index (register-index reg class number))
				      (reg-type (register-class-type class))
				      (reg-width (register-class-width class))
				      (width (1+ (- end begin)))
				      (reg-reg (make-tmp-name)))
				  (format nil "{
reg_t ~A = ref_~A_reg_for_reading(~A);
~A = ref_~A_reg_for_writing(~A);
emit(COMPOSE_SLL_IMM(~A, ~A, ~A));
unref_~A_reg(~A);
emit(COMPOSE_SRL_IMM(~A, ~A, ~A));
}~%"
					  reg-reg (dcs reg-type) reg-index
					  target (dcs reg-type) foreign-target
					  reg-reg (- 63 end) target
					  (dcs reg-type) reg-reg
					  target (- 64 width) target)))
		   (numbered-subregister (reg class number width index)
					 (let ((reg-index (register-index reg class number))
					       (reg-type (register-class-type class))
					       (reg-reg (make-tmp-name)))
					   (format nil "{
word_32 index = ~A;
reg_t ~A = ref_~A_reg_for_reading(~A);
~A = ref_~A_reg_for_writing(~A);
emit(COMPOSE_SLL_IMM(~A, 64 - (index + 1) * ~A, ~A));
unref_~A_reg(~A);
emit(COMPOSE_SRL_IMM(~A, ~A, ~A));
}~%"
						   (generate-interpreter index nil)
						   reg-reg (dcs reg-type) reg-index
						   target (dcs reg-type) foreign-target
						   reg-reg width target
						   (dcs reg-type) reg-reg
						   target (- 64 width) target)))
		   (mem (addr)
			(let ((addr-reg (make-tmp-name)))
			  (format nil "{
reg_t ~A;
~A/* emit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A)); */
~A = ref_~A_reg_for_writing(~A);
emit_load_mem_~A(~A, ~A);
unref_integer_reg(~A);
}~%"
				  addr-reg
				  (generate-compiler addr-reg addr bindings) addr-reg addr-reg
				  target (dcs (expr-type expr)) foreign-target
				  (expr-width expr) target addr-reg
				  addr-reg)))
		   (zex (value)
			(let ((value-code (generate-compiler target value bindings :foreign-target foreign-target)))
			  (if (and (= (expr-width expr) 64) (= (expr-width value) 32))
			      (format nil "~Aemit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A));~%" value-code target target)
			      (progn
				(when (> (expr-width expr) 32)
				  (error "cannot zero extend to ~A bits~%" (expr-width expr)))
				value-code))))
		   (sex (value)
			(format nil "~Aemit(COMPOSE_SLL_IMM(~A, ~A, ~A));
emit(COMPOSE_SRA_IMM(~A, ~A, ~A));~%"
				(generate-compiler target value bindings :foreign-target foreign-target)
				target (- 64 (expr-width value)) target
				target (- 64 (expr-width value)) target))
		   (+carry (op1 op2)
			   (let ((op1-reg (make-tmp-name))
				 (op2-reg (make-tmp-name))
				 (op1-zapped-reg (make-tmp-name))
				 (op2-zapped-reg (make-tmp-name)))
			     (format nil "{
reg_t ~A, ~A, ~A, ~A;
~A~A = ref_integer_reg_for_writing(-1);
emit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A));
unref_integer_reg(~A);
~A~A = ref_integer_reg_for_writing(-1);
emit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A));
unref_integer_reg(~A);
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_ADDQ(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
emit(COMPOSE_SRL_IMM(~A, 32, ~A));
}~%"
				     op1-reg op2-reg op1-zapped-reg op2-zapped-reg
				     (generate-compiler op1-reg op1 bindings) op1-zapped-reg
				     op1-reg op1-zapped-reg
				     op1-reg
				     (generate-compiler op2-reg op2 bindings) op2-zapped-reg
				     op2-reg op2-zapped-reg
				     op2-reg
				     target foreign-target
				     op1-zapped-reg op2-zapped-reg target
				     op1-zapped-reg
				     op2-zapped-reg
				     target target)))
		   (shiftl (value amount)
			   (let ((value-reg (make-tmp-name))
				 (amount-reg (make-tmp-name)))
			     (format nil "{
reg_t ~A, ~A;
~A~A~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_SLL(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
~A}~%"
				     value-reg amount-reg
				     (generate-compiler value-reg value bindings)
				     (generate-compiler amount-reg amount bindings) target foreign-target
				     value-reg amount-reg target
				     value-reg
				     amount-reg
				     (if (= (expr-width expr) 64)
					 ""
					 (progn
					   (unless (= (expr-width expr) 32)
					     (error "cannot shiftl width ~A~%" (expr-width expr)))
					   (format nil
						   "emit(COMPOSE_ADDL(~A, 31, ~A));~%"
						   target target))))))
		   (shiftr (value amount)
			   (let ((value-reg (make-tmp-name))
				 (amount-reg (make-tmp-name)))
			     (if (= (expr-width expr) 64)
				 (format nil "{
reg_t ~A, ~A;
~A~A~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_SRL(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
}~%"
					 value-reg amount-reg
					 (generate-compiler value-reg value bindings)
					 (generate-compiler amount-reg amount bindings) target foreign-target
					 value-reg amount-reg target
					 value-reg
					 amount-reg)
				 (progn
				   (unless (= (expr-width expr) 32)
				     (error "cannot shiftr width ~A~%" (expr-width expr)))
				   (format nil "{
reg_t ~A, ~A;
~A~Aemit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A));
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_SRL(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
emit(COMPOSE_ADDL(~A, 31, ~A));
}~%"
					   value-reg amount-reg
					   (generate-compiler value-reg value bindings)
					   (generate-compiler amount-reg amount bindings) value-reg value-reg
					   target foreign-target
					   value-reg amount-reg target
					   value-reg
					   amount-reg
					   target target)))))
		   (rotl (value amount)
			 (let ((tmp-reg (make-tmp-name))
			       (value-reg (make-tmp-name))
			       (zapped-reg (make-tmp-name)))
			   (format nil "{
reg_t ~A, ~A, ~A;
word_64 amount = ~A;
if (amount == 0)
{
~A}
else
{
~A~A = ref_integer_reg_for_writing(-1);
emit(COMPOSE_ZAPNOT_IMM(~A, 15, ~A));
unref_integer_reg(~A);
~A = ref_integer_reg_for_writing(-1);
emit(COMPOSE_SLL_IMM(~A, amount, ~A));
emit(COMPOSE_SLL_IMM(~A, 32 + amount, ~A));
emit(COMPOSE_BIS(~A, ~A, ~A));
unref_integer_reg(~A);
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_SRA_IMM(~A, 32, ~A));
unref_integer_reg(~A);
}
}~%"
				   tmp-reg value-reg zapped-reg
				   (generate-interpreter amount nil)
				   (generate-compiler target value bindings :foreign-target foreign-target)
				   (generate-compiler value-reg value bindings) zapped-reg
				   value-reg zapped-reg
				   value-reg
				   tmp-reg
				   zapped-reg tmp-reg
				   zapped-reg zapped-reg
				   zapped-reg tmp-reg zapped-reg
				   tmp-reg
				   target foreign-target
				   zapped-reg target
				   zapped-reg)))
		   (leading-zeros (value)
				  (let ((tmp-reg (make-tmp-name)))
				    (format nil "{
reg_t ~A;
~Aemit(COMPOSE_LDQ(0, LEADING_ZEROS_CONST * 4, CONSTANT_AREA_REG));
emit(COMPOSE_LDQ(PROCEDURE_VALUE_REG, C_STUB_CONST * 4, CONSTANT_AREA_REG));
emit(COMPOSE_JMP(RETURN_ADDR_REG, PROCEDURE_VALUE_REG));
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_MOV(0, ~A));
}~%"
					    tmp-reg
					    (generate-compiler tmp-reg value bindings :foreign-target "16 | NEED_NATIVE")
					    target foreign-target
					    target)))
		   (convert-float (value) (generate-compiler target value bindings :foreign-target foreign-target))
		   (bits-to-float (value)
				  (let ((bits-reg (make-tmp-name))
					(float-char (if (= (expr-width expr) 32) "S" "T"))
					(int-char (if (= (expr-width expr) 32) "L" "Q")))
				    (format nil "{
reg_t ~A;
~Aemit(COMPOSE_ST~A(~A, SCRATCH_OFFSET, CONSTANT_AREA_REG));
unref_integer_reg(~A);
~A = ref_float_reg_for_writing(~A);
emit(COMPOSE_LD~A(~A, SCRATCH_OFFSET, CONSTANT_AREA_REG));
}~%"
					    bits-reg
					    (generate-compiler bits-reg value bindings) int-char bits-reg
					    bits-reg
					    target foreign-target
					    float-char target)))
		   (float-to-bits (value)
				  (let ((float-reg (make-tmp-name))
					(float-char (if (= (expr-width expr) 32) "S" "T"))
					(int-char (if (= (expr-width expr) 32) "L" "Q")))
				    (format nil "{
reg_t ~A;
~Aemit(COMPOSE_ST~A(~A, SCRATCH_OFFSET, CONSTANT_AREA_REG));
unref_float_reg(~A);
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_LD~A(~A, SCRATCH_OFFSET, CONSTANT_AREA_REG));
}~%"
					    float-reg
					    (generate-compiler float-reg value bindings) float-char float-reg
					    float-reg
					    target foreign-target
					    int-char target)))
		   (float-to-integer (value)
				     (let* ((float-reg (make-tmp-name))
					    (float-int-reg (make-tmp-name))
					    (width (expr-width expr))
					    (float-char (if (= width 32) "S" "T"))
					    (int-char (if (= width 32) "L" "Q")))
				       (format nil "{
reg_t ~A, ~A;
~A~A = ref_float_reg_for_writing(-1);
emit(COMPOSE_CVTTQC(~A, ~A));
unref_float_reg(~A);
~A
emit(COMPOSE_ST~A(~A, SCRATCH_OFFSET, CONSTANT_AREA_REG));
unref_float_reg(~A);
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_LD~A(~A, SCRATCH_OFFSET, CONSTANT_AREA_REG));
}~%"
					       float-reg float-int-reg
					       (generate-compiler float-reg value bindings) float-int-reg
					       float-reg float-int-reg
					       float-reg
					       (if (= width 32) (format nil "emit(COMPOSE_CVTQL(~A, ~A));~%" float-int-reg float-int-reg) "")
					       float-char float-int-reg
					       float-int-reg
					       target foreign-target
					       int-char target)))
		   (nop () (format nil "/* nop */~%"))
		   (ignore (value) (format nil "/* ignore */~%"))
		   (system-call () (format nil "store_and_free_all_foreign_regs();
emit_system_call();~%"))
		   ((= < <f <s <= > >f >s >=) (left right)
		    (destructuring-bind (op swap)
			(cadr (assoc (expr-kind expr) '((= ("EQ" nil))
							(< ("ULT" nil)) (<f ("LT" nil)) (<s ("LT" nil))
							(<= ("ULE" nil))
							(> ("ULT" t)) (>f ("LT" t)) (>s ("LT" t))
							(>= ("ULE" t)))))
		      (let* ((left-reg (make-tmp-name))
			     (right-reg (make-tmp-name))
			     (result-reg (make-tmp-name))
			     (type (expr-type left))
			     (type-cmp-str (if (eq type 'integer) "" "T"))
			     (type-branch-str (if (eq type 'integer) "" "F")))
			(format nil "{
reg_t ~A, ~A, ~A;
~A~A~A = ref_~A_reg_for_writing(-1);
emit(COMPOSE_CMP~A~A(~A, ~A, ~A));
unref_~A_reg(~A);
unref_~A_reg(~A);
emit_branch(COMPOSE_~ABEQ(~A, 0), ~A);
unref_~A_reg(~A);
emit_branch(COMPOSE_BR(31, 0), ~A);
}~%"
				left-reg right-reg result-reg
				(generate-compiler left-reg left bindings)
				(generate-compiler right-reg right bindings)
				result-reg (dcs type)
				type-cmp-str op (if swap right-reg left-reg) (if swap left-reg right-reg) result-reg
				(dcs type) left-reg
				(dcs type) right-reg
				type-branch-str result-reg false-label
				(dcs type) result-reg
				true-label))))
		   ((logor logand logxor ashiftr) (left right)
		    (let ((op (cadr (assoc (expr-kind expr) '((logor "BIS") (logand "AND") (logxor "XOR") (ashiftr "SRA"))))))
		      (let ((left-reg (make-tmp-name))
			    (right-reg (make-tmp-name)))
			(format nil "{
reg_t ~A, ~A;
~A~A~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_~A(~A, ~A, ~A));
unref_integer_reg(~A);
unref_integer_reg(~A);
}~%"
				left-reg right-reg
				(generate-compiler left-reg left bindings)
				(generate-compiler right-reg right bindings) target foreign-target
				op left-reg right-reg target
				left-reg
				right-reg))))
		   ((neg fneg bitneg) (value)
		    (let ((op (cadr (assoc (expr-kind expr) '((neg "NEGQ") (fneg "FNEGT") (bitneg "NOT")))))
			  (value-reg (make-tmp-name))
			  (type (expr-type expr)))
		      (format nil "{
reg_t ~A;
~A~A = ref_~A_reg_for_writing(~A);
emit(COMPOSE_~A(~A, ~A));
unref_~A_reg(~A);
}~%"
			      value-reg
			      (generate-compiler value-reg value bindings) target (dcs type) foreign-target
			      op value-reg target
			      (dcs type) value-reg)))
		   ((+ +f - -f * *s *f /f) (left right)
		    (let* ((op (cadr (assoc (expr-kind expr) '((+ "ADD~A") (+f "ADD~A") (- "SUB~A") (-f "SUB~A")
							       (* "MUL~A") (*s "MUL~A") (*f "MUL~A") (/f "DIV~A")))))
			   (left-reg (make-tmp-name))
			   (right-reg (make-tmp-name))
			   (type (expr-type expr))
			   (width (expr-width expr))
			   (type-char (if (eq type 'float) "T" (cadr (assoc width '((32 "L") (64 "Q"))))))
			   (op (format nil op type-char)))
		      (format nil "{
reg_t ~A, ~A;
~A~A~A = ref_~A_reg_for_writing(~A);
emit(COMPOSE_~A(~A, ~A, ~A));
unref_~A_reg(~A);
unref_~A_reg(~A);
}~%"
			      left-reg right-reg
			      (generate-compiler left-reg left bindings)
			      (generate-compiler right-reg right bindings) target (dcs type) foreign-target
			      op left-reg right-reg target
			      (dcs type) left-reg
			      (dcs type) right-reg)))
		   ((/ /s) (left right)
		    (let ((const (cadr (assoc (expr-kind expr) '((/ "DIV_UNSIGNED_32_CONST") (/s "DIV_SIGNED_32_CONST"))))))
		      (let ((left-reg (make-tmp-name))
			    (right-reg (make-tmp-name)))
			(format nil "{
reg_t ~A, ~A;
~A~Aemit(COMPOSE_MOV(~A, 16));
emit(COMPOSE_MOV(~A, 17));
unref_integer_reg(~A);
unref_integer_reg(~A);
emit(COMPOSE_LDQ(0, ~A * 4, CONSTANT_AREA_REG));
emit(COMPOSE_LDQ(PROCEDURE_VALUE_REG, C_STUB_CONST * 4, CONSTANT_AREA_REG));
emit(COMPOSE_JMP(RETURN_ADDR_REG, PROCEDURE_VALUE_REG));
~A = ref_integer_reg_for_writing(~A);
emit(COMPOSE_MOV(0, ~A));
}~%"
				left-reg right-reg
				(generate-compiler left-reg left bindings)
				(generate-compiler right-reg right bindings)
				left-reg right-reg
				left-reg right-reg
				const
				target foreign-target
				target)))))))))))

(defun generate-expr-code (expr &optional required-width (required-type 'integer))
  (generate-interpreter (generate-expr expr nil required-width required-type) nil))

(defun generate-code-for-insn (insn)
  (dolist (expr (insn-effect insn))
    (format t "~A;~%" (generate-interpreter expr nil))))

(defun expr-to-sexp (expr)
  (cond ((expr-p expr)
	 (cons (expr-kind expr) (mapcar #'expr-to-sexp (expr-operands expr))))
	((register-class-p expr)
	 (register-class-name expr))
	(t
	 expr)))

(defun lookup-register-mapping (expr)
  (case (expr-kind expr)
    ((register subregister)
     (let* ((reg (first (expr-operands expr)))
	    (class (second (expr-operands expr)))
	    (name (if (null reg) (register-class-name class) (register-name reg))))
       (destructuring-bind (name class-name sex)
	   (assoc name *register-mapping*)
	 (values (lookup-register-class class-name *target-machine*) sex))))
    (target-register
     (values (second (expr-operands expr)) nil))
    (t
     (error "unknown register expr: ~A~%" expr))))

(defun match-pattern (expr pattern)
  (labels ((match-binop (expr pattern)
	     (destructuring-bind (op1 op2)
		 (expr-operands pattern)
	       (destructuring-bind (expr-op1 expr-op2)
		   (expr-operands expr)
		 (multiple-value-bind (success read-bindings1 write-bindings1)
		     (match-pattern expr-op1 op1)
		   (if success
		       (multiple-value-bind (success read-bindings2 write-bindings2)
			   (match-pattern expr-op2 op2)
			 (if success
			     (values t (append read-bindings1 read-bindings2) (append write-bindings1 write-bindings2))
			     (values nil (cons 'binop-op2-fail read-bindings2))))
		       (values nil (cons 'binop-op1-fail read-bindings1)))))))
	   (match (expr pattern)
;	     (format t "matching ~A against ~A~%" expr pattern)
	     (if (and (eq (expr-type expr) (expr-type pattern))
		      (eql (expr-width expr) (expr-width pattern)))
		 (expr-case pattern
		   (input (name)
			  (values t (list (cons pattern expr)) nil))
		   (register (reg class number)
			     (values t (list (cons pattern expr)) nil))
		   (subregister (reg class number begin end named)
				(values t (list (cons pattern expr)) nil))
		   (integer (value)
			    (values t (list (cons pattern expr)) nil))
		   (t
		    (if (eq (expr-kind expr) (expr-kind pattern))
			(expr-case pattern
			  (set (lvalue rhs)
			       (destructuring-bind (expr-lvalue expr-rhs)
				   (expr-operands expr)
				 (cond ((or (and (eq (expr-kind lvalue) 'register)
						 (or (eq (expr-kind expr-lvalue) 'register)
						     (eq (expr-kind expr-lvalue) 'target-register)))
					    (and (eq (expr-kind lvalue) 'subregister)
						 (or (eq (expr-kind expr-lvalue) 'subregister)
						     (eq (expr-kind expr-lvalue) 'target-subregister))))
					(multiple-value-bind (success read-bindings write-bindings)
					    (match-pattern expr-rhs rhs)
					  (if success
					      (values t read-bindings (cons (cons lvalue expr-lvalue) write-bindings))
					      (values nil (cons 'set-reg-rhs-fail read-bindings)))))
				       ((and (eq (expr-kind lvalue) 'mem)
					     (eq (expr-kind expr-lvalue) 'mem)
					     (= (first (expr-operands lvalue)) (first (expr-operands expr-lvalue))))
					(multiple-value-bind (success addr-read-bindings addr-write-bindings)
					    (match-pattern (second (expr-operands expr-lvalue)) (second (expr-operands lvalue)))
					  (if success
					      (multiple-value-bind (success rhs-read-bindings rhs-write-bindings)
						  (match-pattern expr-rhs rhs)
						(if success
						    (values t
							    (append addr-read-bindings rhs-read-bindings)
							    (append addr-write-bindings rhs-write-bindings))
						    (values nil (cons 'set-mem-rhs-fail rhs-read-bindings))))
					      (values nil (cons 'set-mem-addr-fail addr-read-bindings)))))
				       (t
					(values nil 'set-lvalue-kind-fail)))))
			  (logand (op1 op2) ;FIXME: we should resolve op2 here (could be an input)
				  (destructuring-bind (expr-op1 expr-op2)
				      (expr-operands expr)
				    (if (and (eq (expr-kind op2) 'integer) (eq (expr-kind expr-op2) 'integer))
					(let ((op2-value (first (expr-operands op2)))
					      (expr-op2-value (first (expr-operands expr-op2))))
					  (if (= (logand op2-value expr-op2-value) expr-op2-value)
					      (match-pattern expr op1)
					      (values nil 'logand-values-fail)))
					(match-binop expr pattern))))
			  ((+ - * shiftl shiftr logand logor logxor) (op1 op2)
			   (match-binop expr pattern))
			  ((sex zex bitneg mem) (value)
			       (match-pattern (first (expr-operands expr)) value)))
			(values nil 'expr-kind-fail))))
		 (values nil 'expr-type-or-width-fail))))
    (dolist (alternative (expr-alternatives expr))
      (multiple-value-bind (success read-bindings write-bindings)
	  (match alternative pattern)
	(when (and success
		   (every #'(lambda (x)
			      (let ((pattern (car x))
				    (expr (cdr x)))
				(not (and (expr-constp pattern) (not (expr-constp expr))))))
			  read-bindings)
		   (every #'(lambda (x) (let* ((pattern (car x))
					       (expr (cdr x))
					       (target-class (lookup-register-mapping expr)))
					  (eq target-class (second (expr-operands pattern)))))
			  write-bindings))
;	  (format t "success with ~A against ~A~%" alternative pattern)
	  (return-from match-pattern (values success read-bindings write-bindings)))))
    nil))

(defun generate-match-code (insn generator read-bindings write-bindings fail-label)
  (let* ((bindings nil)
	 (delayed-bindings nil)
	 (input-bindings nil)
	 (register-frees nil)
	 (obeyed-constraints nil)
	 (can-fail nil)
	 (num-insns 1)
	 (text (with-output-to-string (out)
		 (labels ((match-fields (pattern expr binding)
			    (labels ((evade ()
;				       (format t "evading with ~A and ~A (~A)~%" pattern expr input-bindings)
				       (compute-fields pattern (generate-interpreter expr nil) binding)))
			      (let ((expr (if (eq (expr-kind expr) 'input)
					      (cdr (assoc (first (expr-operands expr)) input-bindings))
					      expr)))
				(if (not (null expr))
				    (cond ((eq (expr-kind (simplify expr)) 'integer)
					   (let* ((expr (simplify expr))
						  (value (first (expr-operands expr))))
					     (expr-case pattern
					       (sex (pattern-op)
						    (let* ((op-width (expr-width pattern-op))
							   (diff (- (expr-width pattern) op-width))
							   (extension (ash value (- op-width))))
						      (if (or (zerop extension)
							      (= extension (1- (expt 2 diff))))
							  (match-fields pattern-op
									(make-integer-expr (expr-width expr) (logand value (1- (ash 1 op-width))))
									binding)
							  (error "static mismatch: ~A ~A~%" pattern expr))))
					       (zex (pattern-op)
						    (if (zerop (ash value (- (expr-width pattern-op))))
							(match-fields pattern-op expr binding)
							(return-from generate-match-code nil)))
					       (shiftl (pattern-value amount)
						       (if (eq (expr-kind amount) 'integer)
							   (let ((amount (first (expr-operands amount))))
							     (if (zerop (logand value (1- (ash 1 amount))))
								 (match-fields pattern-value
									       (make-integer-expr (expr-width expr) (ash value amount))
									       binding)
								 (return-from generate-match-code nil)))
							   (evade)))
					       (maskmask (bit-width mask)
							 (let ((inverted (invert-maskmask bit-width value)))
							   (if (null inverted)
							       (return-from generate-match-code nil)
							       (match-fields mask (make-integer-expr (expr-width mask) inverted) binding))))
					       (t
						(evade)))))
					  ((and (eq (expr-kind pattern) (expr-kind expr))
						(eq (expr-type pattern) (expr-type expr))
						(= (expr-width pattern) (expr-width expr)))
					   (expr-case expr
					     (sex (expr-op)
						  (let ((pattern-op (first (expr-operands pattern))))
						    (if (= (expr-width pattern-op) (expr-width expr-op))
							(match-fields pattern-op expr-op binding)
							(evade))))
					     (t
					      (evade))))
					  (t
					   (evade)))
				    (evade)))))
			  (compute-fields (expr value binding)
			    (expr-case expr
			      (field (name begin end)
				     (let ((c-name (format nil "field_~A" (dcs name))))
				       (push (cons name binding) bindings)
				       (format nil "~A = ~A;~%" c-name value)))
			      (sex (op)
				   (let* ((name (make-tmp-name))
					  (op-width (expr-width op))
					  (diff (- (expr-width expr) op-width)))
				     (setf can-fail t)
				     (format nil "{
~A ~A = ~A;
if ((~A >> ~A) == 0x~X || (~A >> ~A) == 0)
~Aelse goto ~A;
}~%"
					     (c-type (expr-width expr) 'integer) name value
					     name op-width (1- (expt 2 diff)) name op-width
					     (compute-fields op (format nil "(~A & 0x~X)" name (1- (ash 1 op-width))) binding)
					     fail-label)))
			      (zex (op)
				   (let ((name (make-tmp-name)))
				     (setf can-fail t)
				     (format nil "{
~A ~A = ~A;
if ((~A >> ~A) == 0)
~Aelse goto ~A;
}~%"
					     (c-type (expr-width expr) 'integer) name value
					     name (expr-width op)
					     (compute-fields op name binding)
					     fail-label)))
			      (bitneg (op)
				      (compute-fields op (format nil "(~~~A & 0x~X)" value (1- (ash 1 (expr-width expr)))) binding))
			      (shiftl (op amount)
				      (unless (eq (expr-kind amount) 'integer)
					(format t "trying to invert shiftl with non-constant amount~%")
					(return-from generate-match-code nil))
				      (let ((amount (first (expr-operands amount)))
					    (name (make-tmp-name)))
					(setf can-fail t)
					(format nil "{
~A ~A = ~A;
if ((~A & 0x~X) == 0)
~Aelse goto ~A;
}~%"
						(c-type (expr-width expr) 'integer) name value
						name (1- (ash 1 amount))
						(compute-fields op (format nil "(~A >> ~A)" name amount) binding)
						fail-label)))
			      (shiftr (op amount)
				      (unless (eq (expr-kind amount) 'integer)
					(format t "trying to invert shiftr with non-constant amount~%")
					(return-from generate-match-code nil))
				      (let ((amount (first (expr-operands amount)))
					    (name (make-tmp-name)))
					(setf can-fail t)
					(format nil "{
~A ~A = ~A;
if ((~A & 0x~X) == 0)
~Aelse goto ~A;
}~%"
						(c-type (expr-width expr) 'integer) name value
						name (integer-bit-range (- (expr-width expr) amount) (1- (expr-width expr)))
						(compute-fields op (format nil "(~A << ~A)" name amount) binding)
						fail-label)))
			      (maskmask (bit-width mask)
					(let ((name (make-tmp-name)))
					  (setf can-fail t)
					  (format nil "{
~A ~A = ~A;
if (can_inv_maskmask(~A, ~A))
~Aelse goto ~A;
}~%"
						  (c-type (expr-width expr) 'integer) name value
						  bit-width name
						  (compute-fields mask (format nil "inv_maskmask(~A, ~A)" bit-width name) binding)
						  fail-label))))))
		   (let ((variables (remove-duplicates (append (mappend #'(lambda (x)
									    (all-inputs-and-fields (car x)))
									(append read-bindings write-bindings))
							       (mappend #'all-inputs-and-fields (cadr generator))))))
		     (dolist (variable variables)
		       (format out "~A ~A;~%"
			       (c-type (expr-width variable) (expr-type variable))
			       (expr-case variable
				 (input (name) name)
				 (field (name begin end) (format nil "field_~A" (dcs name)))))))
		   (dolist (binding read-bindings)
		     (let ((pattern (car binding))
			   (expr (simplify (cdr binding))))
		       (expr-case pattern
			 (input (name)
				(format out "~A = ~A;~%" name (generate-interpreter expr nil))
				(push (cons name '(input)) bindings)
				(push (cons name expr) input-bindings))
			 (integer (value)
				  (if (eq (expr-kind expr) 'integer)
				      (when (/= value (first (expr-operands expr)))
					(return-from generate-match-code nil))
				      (progn
					(setf can-fail t)
					(format out "if (~A != ~A) goto ~A;~%" value (generate-interpreter expr nil) fail-label))))
			 (register (reg class number)
				   (push (cons (first (expr-operands number)) `(register ,class)) bindings))
			 (subregister (reg class number begin end named)
				      (push (cons (first (expr-operands number)) `(register ,class)) bindings)))))
		   (dolist (binding write-bindings)
		     (let ((pattern (car binding)))
		       (push (cons (first (expr-operands (third (expr-operands pattern)))) `(register ,(second (expr-operands pattern)))) bindings)))
		   (let ((*take-fields-from-variables* t))
		     (labels ((loop ()
				(let ((changes nil))
				  (dolist (constraint (cadr generator))
				    (when (eq (expr-kind constraint) '=)
				      (let* ((bounds (mapcar #'car bindings))
					     (unbounds (set-difference (all-input-and-field-names constraint) bounds)))
					(when (= (length unbounds) 1)
					  (let ((unbound (car unbounds)))
					    (cond ((eq (expr-kind (first (expr-operands constraint))) 'input)
						   (let* ((binding-type (cdr (assoc (first (expr-operands (first (expr-operands constraint))))
										    bindings)))
							  (binding-text (match-fields (second (expr-operands constraint))
										      (first (expr-operands constraint))
										      binding-type)))
						     (if (eq (car binding-type) 'register)
							 (push binding-text delayed-bindings)
							 (princ binding-text out))))
						  ((null (set-difference (all-input-and-field-names (first (expr-operands constraint))) bounds))
						   (princ (match-fields (second (expr-operands constraint))
									(first (expr-operands constraint))
									'(input))
							  out))
						  (t
						   (princ (match-fields (first (expr-operands constraint))
									(second (expr-operands constraint))
									'(input))
							  out)))
					    (setf changes t)
					    (push constraint obeyed-constraints))))))
				  (when changes
				    (loop)))))
		       (loop))
		     (let ((bounds (mapcar #'car bindings))
			   (register-bounds (mapcar #'car (remove-if-not #'(lambda (x) (eq (cadr x) 'register)) bindings))))
		       (dolist (constraint (cadr generator))
			 (unless (member constraint obeyed-constraints)
			   (let ((all-inputs-and-fields (all-input-and-field-names constraint)))
			     (unless (null (set-difference all-inputs-and-fields bounds))
			       (error "unbounds in constraint ~A~%" constraint))
			     (unless (or (null (intersection all-inputs-and-fields register-bounds))
					 (null (set-difference all-inputs-and-fields register-bounds)))
			       (error "register bounds in constraint ~A~%" constraint))
			     (when (null (intersection all-inputs-and-fields register-bounds))
			       (setf can-fail t)
			       (format out "if (!~A) goto ~A;~%" (generate-interpreter constraint nil) fail-label)))))))
					;      (format t "~%~%~A~%~%" bindings)
		   (format out "/* commit */~%")
		   (dolist (binding read-bindings)
		     (let ((pattern (car binding))
			   (expr (cdr binding)))
		       (expr-case pattern
			 (input (name)
				t)
			 (integer (value)
				  t)
			 (register (reg class number)
				   (cond ((expr-constp expr)
					  (let ((name (first (expr-operands number))))
					    (format out "~A = ref_~A_reg_for_writing(-1);~%emit_load_~A_~A(~A, ~A);~%"
						    name
						    (dcs (register-class-name class))
						    (dcs (register-class-type class))
						    (expr-width expr)
						    name
						    (generate-interpreter expr nil))
					    (incf num-insns)))
					 ((eq (expr-kind expr) 'register)
					  (format out "~A = ref_~A_reg_for_reading(~A);~%"
						  (first (expr-operands number))
						  (dcs (register-class-name class))
						  (generate-interpreter (third (expr-operands expr)) nil)))
					 (t
					  (let* ((source-class (lookup-register-class 'gpr *source-machine*))
						 (reg-var-name (first (expr-operands number)))
						 (source-reg (make-expr :kind 'target-register
									:type (expr-type expr) :width (expr-width expr)
									:operands (list reg-var-name class)))
						 (effect (list (make-expr :kind 'set :operands (list source-reg expr))))
						 (label (make-tmp-name)))
					    (if (may-generate-effect (car effect))
						(progn
						  (format t "matching with reg: ~A~%" effect)
						  (format out "{~%")
						  (incf num-insns (generate-effect-compiler effect label out))
						  (format out "~A:~%}~%" label))
						(return-from generate-match-code nil)))))
				   (push (format nil "unref_~A_reg(~A);~%" (dcs (register-class-name class)) (first (expr-operands number)))
					 register-frees))
			 (subregister (reg class number begin end named)
				      (cond ((expr-constp expr)
					     (let ((name (first (expr-operands number))))
					       (format out "~A = ref_~A_reg_for_writing(-1);~%emit_load_~A_~A(~A, ~A);~%"
						       name
						       (dcs (register-class-name class))
						       (dcs (register-class-type class))
						       (expr-width expr)
						       name
						       (generate-interpreter expr nil))
					       (incf num-insns)))
					    ((eq (expr-kind expr) 'subregister)
					     (format out "~A = ref_~A_reg_for_reading(~A);~%"
						     (first (expr-operands number))
						     (dcs (register-class-name class))
						     (generate-interpreter (third (expr-operands expr)) nil)))
					    (t
					     (let* ((source-class (lookup-register-class 'gpr *source-machine*))
						    (reg-var-name (first (expr-operands number)))
						    (source-reg (make-expr :kind 'target-subregister
									   :type (expr-type expr) :width (expr-width expr)
									   :operands (list reg-var-name class begin end)))
						    (effect (list (make-expr :kind 'set :operands (list source-reg expr))))
						    (label (make-tmp-name)))
					       (if (may-generate-effect (car effect))
						   (progn
						     (format t "matching with subreg: ~A~%" effect)
						     (format out "{~%")
						     (incf num-insns (generate-effect-compiler effect label out))
						     (format out "~A:~%}~%" label))
						   (return-from generate-match-code nil)))))
				      (push (format nil "unref_~A_reg(~A);~%" (dcs (register-class-name class)) (first (expr-operands number)))
					    register-frees)))))
		   (dolist (binding write-bindings)
		     (let ((pattern (car binding))
			   (expr (cdr binding)))
		       (case (expr-kind expr)
			 (target-register
			  (format out "~A = ref_~A_reg_for_writing(-1);~%"
				  (first (expr-operands expr))
				  (dcs (register-class-name (second (expr-operands expr))))))
			 (t
			  (let ((reg-var-name (first (expr-operands (third (expr-operands pattern)))))
				(reg-class-name (dcs (register-class-name (second (expr-operands pattern))))))
			    (format out "~A = ref_~A_reg_for_writing(~A);~%"
				    reg-var-name
				    reg-class-name
				    (generate-interpreter (third (expr-operands expr)) nil))
			    (push (format nil "unref_~A_reg(~A);~%" reg-class-name reg-var-name) register-frees))))))
		   (mapc #'(lambda (x) (princ x out)) (reverse delayed-bindings))
		   (format out "emit(COMPOSE_~A(~{~A~^, ~}));~%" (insn-name insn) (mapcar #'(lambda (x) (format nil "field_~A" (dcs x)))
											  (insn-operands insn)))
		   (mapc #'(lambda (x) (princ x out)) register-frees))
		 (format out "/* can fail: ~A   num insns: ~A */~%" can-fail num-insns))))
    (values text can-fail num-insns)))

(defun all-generator-matches (source-effect)
  (let ((matches nil))
    (dolist (insn (machine-insns *target-machine*))
      (when (and (insn-generate insn)
		 (or (eq *used-target-insns* :all)
		     (member (insn-name insn) *used-target-insns*)))
	(dolist (generator (insn-generators insn))
	  (when (= (length (car generator)) 1)
	    (multiple-value-bind (success read-bindings write-bindings)
		(match-pattern source-effect (caar generator))
	      (when success
		(if (= (length *effects-in-generation*) 1)
		  (format t "toplevel success: ~A~%" (insn-name insn))
		  (format t "effects in generation: ~A~%" (length *effects-in-generation*)))
		(push (list insn generator read-bindings write-bindings) matches)))))))
    matches))

(defun decompose-insn-effect (insn make-inputs)
  (labels ((generate (expr)
	     (cond ((member (expr-kind expr) '(integer float))
		    (choices (list expr nil)))
		   ((and make-inputs (expr-constp expr))
		    (let ((input-expr (make-expr :kind 'input :type (expr-type expr) :width (expr-width expr) :operands (list (make-tmp-name)))))
		      (choices (list input-expr (list (make-expr :kind '= :operands (list input-expr expr)))))))
		   (t
		    (expr-case expr
		      (set (lvalue rhs)
			   (collect-choices (rhs-pattern rhs-constraints)
			       (generate rhs)
			     (expr-case lvalue
			       (register (reg class number)
					 (collect-choices (number-pattern number-constraints)
					     (generate number)
					   (choices (list (make-expr :kind 'set
								     :operands (list (make-expr :kind 'register :type (register-class-type class)
												:width (register-class-width class)
												:operands (list reg class number-pattern))
										     rhs-pattern))
							  (append rhs-constraints number-constraints)))))
			       (subregister (subreg)
					    (choices (list (make-expr :kind 'set :operands (list subreg rhs-pattern)) rhs-constraints)))
			       (numbered-subregister (reg class number width index)
						     (collect-choices (number-pattern number-constraints)
							 (generate number)
						       (collect-choices (index-pattern index-constraints)
							   (generate index)
							 (choices (list (make-expr :kind 'set
										   :operands (list (make-expr :kind 'numbered-subregister
													      :type (expr-type lvalue)
													      :width width
													      :operands (list reg class
															      number-pattern
															      width index-pattern))
												   rhs-pattern))
									(append rhs-constraints number-constraints index-constraints))))))
			       (mem (width addr)
				    (collect-choices (addr-pattern addr-constraints)
					(generate addr)
				      (choices (list (make-expr :kind 'set
								:operands (list (make-expr :kind 'mem :type (expr-type lvalue) :width width
											   :operands (list width addr-pattern))
										rhs-pattern))
						     (append rhs-constraints addr-constraints))))))))
		      (if (cond cons alt)
			  (if (expr-constp cond)
			      (combine-choices (collect-choices (cons-pattern cons-constraints)
						   (generate cons)
						 (choices (list cons-pattern (cons cond cons-constraints))))
					       (collect-choices (alt-pattern alt-constraints)
						   (generate alt)
						 (choices (list alt-pattern (cons (make-expr :kind 'not :operands (list cond)) alt-constraints)))))
			      (collect-choices (cons-pattern cons-constraints)
				  (generate cons)
				(collect-choices (alt-pattern alt-constraints)
				    (generate alt)
				  (collect-choices (cond-pattern cond-constraints)
				      (generate cond)
				    (choices (list (make-expr :kind 'if :type (expr-type expr) :width (expr-type expr)
							      :operands (list cond-pattern cons-pattern alt-pattern))
						   (append cond-constraints cons-constraints alt-constraints))))))))
		      (register (reg class number)
				(collect-choices (number-pattern number-constraints)
				    (generate number)
				  (choices (list (make-expr :kind 'register :type (expr-type expr) :width (expr-width expr)
							    :operands (list reg class number-pattern)) number-constraints))))
		      (subregister (reg class number begin end named)
				   (collect-choices (number-pattern number-constraints)
				       (generate number)
				     (choices (list (make-expr :kind 'subregister :type (expr-type expr) :width (expr-width expr)
							       :operands (list reg class number-pattern begin end named)) number-constraints))))
		      (numbered-subregister (reg class number width index)
					    (collect-choices (number-pattern number-constraints)
						(generate-number)
					      (collect-choices (index-pattern index-constraints)
						  (generate-number)
						(choices (list (make-expr :kind 'numbered-subregister :type (expr-type expr) :width (expr-width expr)
									  :operands (list reg class number-pattern width index-pattern))
							       (append number-constraints index-constraints))))))
		      (field (name begin end)
			     (choices (list expr nil)))
		      (maskmask (width mask)
				(collect-choices (pattern constraints)
				    (generate mask)
				  (choices (list (make-expr :kind 'maskmask :type (expr-type expr) :width (expr-width expr)
							    :operands (list width pattern))
						 constraints))))
		      ((sex zex promote jump mem leading-zeros trailing-zeros population
			    convert-float bits-to-float float-to-bits float-to-integer integer-to-float
			    ignore
			    neg fneg bitneg sqrt not
			    call-pal) (value)
		                 (collect-choices (pattern constraints)
				     (generate value)
				   (choices (list (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
							     :operands (list pattern)) constraints))))
		      ((logor logand logxor bit-set-p +carry shiftl shiftr ashiftr rotl mask
			       = =f < <f <s <= <=f <=s > >f >s >= >=f >=s
			       + +f - -f * *s *f /f / /s) (op1 op2)
			          (collect-choices (op1-pattern op1-constraints)
				      (generate op1)
				    (collect-choices (op2-pattern op2-constraints)
					(generate op2)
				      (choices (list (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
								:operands (list op1-pattern op2-pattern))
						     (append op1-constraints op2-constraints))))))
		      ((nop system-call not-implemented) ()
			   (choices (list expr nil)))))))
	   (decompose (effect)
	     (if (null effect)
		 (choices (list nil nil))
		 (collect-choices (pattern constraints)
		     (generate (car effect))
		   (collect-choices (rest-patterns rest-constraints)
		       (decompose (cdr effect))
		     (choices (list (cons pattern rest-patterns)
				    (append constraints rest-constraints))))))))
    (when (= (length (insn-effect insn)) 1)
      (let ((generators (all-choices (decompose (insn-effect insn)))))
;	(dolist (generator generators)
;	  (destructuring-bind (pattern constraints)
;	      generator
;	    (format t "***pattern: ~A~%***constraints: ~A~%~%~%" (expr-to-sexp pattern) (mapcar #'expr-to-sexp constraints))))
	generators))))

(defun register-inputs (expr)
  (let ((operand-inputs (mappend #'register-inputs (remove-if-not #'expr-p (expr-operands expr)))))
    (if (and (member (expr-kind expr) '(register subregister numbered-subregister))
	     (eq (expr-kind (third (expr-operands expr))) 'input))
	(cons (first (expr-operands (third (expr-operands expr)))) operand-inputs)
	operand-inputs)))

(defun all-inputs-and-fields (expr)
  (labels ((compute (expr)
	     (case (expr-kind expr)
	       ((input field) (list expr))
	       (t (mappend #'compute (remove-if-not #'expr-p (expr-operands expr)))))))
    (remove-duplicates (compute expr))))

(defun all-input-and-field-names (expr)
  (mapcar #'(lambda (x) (first (expr-operands x))) (all-inputs-and-fields expr)))

(defun generate-all-generators (machine)
  (dolist (insn (machine-insns machine))
    (when (= (length (insn-effect insn)) 1)
;      (format t "~A~%" (insn-name insn))
      (setf (insn-generators insn)
	    (mapcar #'(lambda (x)
			(destructuring-bind (effect constraints)
			    x
			  (list (mapcar #'simplify effect) constraints)))
		    (decompose-insn-effect insn t))))))

;	    (mapcar #'(lambda (generator)
;			(destructuring-bind (pattern constraints)
;			    generator
;			  (list pattern (let ((register-inputs (mappend #'register-inputs pattern)))
;					  (remove-if #'(lambda (constraint)
;							 (null (intersection (all-inputs constraint) register-inputs)))
;						     constraints)))))
;		    )))))

(defvar *effects-in-generation* nil)

(defun may-generate-effect (effect)
  (notany #'(lambda (e)
	      (if (and (eq (expr-kind e) 'set) (eq (expr-kind effect) 'set))
		  (expr-equal-p (second (expr-operands e)) (second (expr-operands effect))) ;FIXME: we need to be more specific
		  (expr-equal-p e effect)))
	  *effects-in-generation*))

;;; returns the number of instructions generated in the worst case.
(defun generate-effect-compiler (effect finish-label out)
  (let ((total-insns 0))
    (dolist (single-effect effect)
      (let ((*effects-in-generation* (cons single-effect *effects-in-generation*)))
	(let* ((matches (all-generator-matches single-effect))
	       (emitters (mapcar* #'(lambda (match)
				      (destructuring-bind (insn generator read-bindings write-bindings)
					  match
					(let ((fail-label (format nil "fail_~A" (make-tmp-name))))
					  (multiple-value-bind (text can-fail num-insns)
					      (generate-match-code insn generator read-bindings write-bindings fail-label)
					    (if text
						(list text can-fail num-insns fail-label insn)
						nil)))))
				  matches))
	       (sorted-emitters (sort emitters #'(lambda (a b)
						   (destructuring-bind (a-text a-can-fail a-num-insns a-fail-label a-insn)
						       a
						     (destructuring-bind (b-text b-can-fail b-num-insns b-fail-label b-insn)
							 b
						       (or (< a-num-insns b-num-insns)
							   (and (= a-num-insns b-num-insns)
								(and a-can-fail (not b-can-fail)))))))))
	       (last-label nil))
	  (format t "~A matches, ~A emitters~%" (length matches) (length emitters))
	  (labels ((loop (emitters label)
		     (when (null emitters)
		       (error "all emitters can fail for ~A~%" single-effect))
		     (destructuring-bind (text can-fail num-insns fail-label insn)
			 (car emitters)
		       (when label
			 (format out "~A:~%" label))
		       (format out "/* ~A */~%" (insn-name insn))
		       (princ text out)
		       (format out "goto ~A;~%" finish-label)
		       (if can-fail
			   (loop (cdr emitters) fail-label)
			   (incf total-insns num-insns)))))
	    (loop sorted-emitters nil)))))
    total-insns))

(defun generate-insn-compiler (insn)
  (let ((decomposed-effect (decompose-insn-effect insn nil)))
    (dolist (effect-with-constraints decomposed-effect)
      (destructuring-bind (effect constraints)
	  effect-with-constraints
	(let ((finish-label (format nil "finish_~A" (make-tmp-name))))
	  (format t "if (~{~A~^ && ~})~%{~%" (mapcar #'(lambda (x) (generate-interpreter x nil)) constraints))
	  (format t "*** effect: ~A~%" (mapcar #'simplify (mapcar #'64bitify effect)))
	  (generate-effect-compiler (mapcar #'simplify (mapcar #'64bitify effect)) finish-label *standard-output*)
	  (format t "~A:~%}~%" finish-label))))))

(defun source-to-target-transform (expr)
  (if (not (expr-p expr))
      expr
      (expr-case expr
	(set (lvalue rhs)
	     (make-expr :kind 'set
			:operands (list (source-to-target-transform lvalue)
					(source-to-target-transform rhs))))
	(if (cond cons alt)
	    (make-expr :kind 'if :type (expr-type expr)
		       :width (expr-width expr)
		       :operands (list (source-to-target-transform cond) (source-to-target-transform cons) (source-to-target-transform alt))))
	((integer float) (value)
		 expr)
	(register (reg class number)
		  (let* ((target-class (lookup-register-mapping expr))
			 (class-width (register-class-width class))
			 (target-class-width (register-class-width target-class)))
		    (if (= class-width target-class-width)
			(make-expr :kind 'register
				   :type (expr-type rhs)
				   :width class-width
				   :operands (list reg class (source-to-target-transform number)))
			(make-expr :kind 'subregister
				   :type (expr-type rhs)
				   :width class-width
				   :operands (list reg class (source-to-target-transform number)
						   0 (1- class-width) nil)))))
	(subregister (reg class number begin end named)
		     (let ((target-class (lookup-register-mapping expr)))
		       (make-expr :kind 'subregister :type (expr-type expr) :width (expr-width expr)
				  :operands (list nil class (source-to-target-transform number nil) begin end named))))
	(field (name begin end)
	       expr)
	(t
	 (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
		    :operands (mapcar #'source-to-target-transform (expr-operands expr)))))))

(defun 64bitify (expr)
  (let ((source-bits (machine-word-bits *source-machine*))
	(target-bits (machine-word-bits *target-machine*)))
    (labels ((convert (expr widen &optional mode)
	       (if (not (expr-p expr))
		   expr
		   (expr-case expr
		     (set (lvalue rhs)
			  (expr-case lvalue
			    (register (reg class number)
				      (multiple-value-bind (target-class sex)
					  (lookup-register-mapping lvalue)
					(make-expr :kind 'set
						   :operands (list (make-expr :kind 'register
									      :type (expr-type rhs)
									      :width (register-class-width target-class)
									      :operands (list reg class (convert number :keep)))
								   (convert rhs
									    (/= (register-class-width class) (register-class-width target-class))
									    (if sex :sex :zex))))))
			    (mem (width addr)
				 (make-expr :kind 'set
					    :operands (list (make-expr :kind 'mem
								       :type (expr-type lvalue)
								       :width (expr-width lvalue)
								       :operands (list width (convert addr t :brutal)))
							    (convert rhs nil))))))
		     (if (cond cons alt)
			 (make-expr :kind 'if :type (expr-type expr)
				    :width (if (and widen (= (expr-width expr) source-bits)) target-bits (expr-width expr))
				    :operands (list (convert cond nil) (convert cons widen mode) (convert alt widen mode))))
		     (integer (value)
			      (if (and widen (= (expr-width expr) source-bits))
				  (make-expr :kind 'integer :type 'integer :width target-bits
					     :operands (list (sign-extend value (expr-width expr) target-bits)))
				  expr))
		     (register (reg class number)
			       (multiple-value-bind (target-class sex)
				   (lookup-register-mapping expr)
				 (if (or widen (= (register-class-width class) (register-class-width target-class)))
				     (make-expr :kind 'register :type (expr-type expr) :width (register-class-width target-class)
						:operands (list nil class (convert number nil)))
				     (make-expr :kind 'subregister :type (expr-type expr) :width (expr-width expr)
						:operands (list nil class (convert number nil) 0 (1- (expr-width expr)) nil)))))
		     (subregister (reg class number begin end named)
				  (multiple-value-bind (target-class sex)
				      (lookup-register-mapping expr)
				    (if (and widen (= begin 0) (= end (1- (register-class-width class))))
					(make-expr :kind 'register :type (expr-type expr) :width (register-class-width target-class)
						   :operands (list nil class (convert number nil)))
					(make-expr :kind 'subregister :type (expr-type expr) :width (expr-width expr)
						   :operands (list nil class (convert number nil) begin end named)))))
		     (mem (addr)
			  (let ((converted-mem-expr (make-expr :kind 'mem :type (expr-type expr) :width (expr-width expr)
							       :operands (list (convert addr t :brutal)))))
			    (if (and widen (= (expr-width expr) source-bits))
				(make-expr :kind (if (eq mode :sex) 'sex 'zex) :type (expr-type expr) :width target-bits
					   :operands (list converted-mem-expr))
				converted-mem-expr)))
		     ((sex zex) (value)
		      (make-expr :kind (expr-kind expr)
				 :type (expr-type expr) :width (if (and widen (= (expr-width expr) source-bits))
								   target-bits
								   (expr-width expr))
				 :operands (list (convert value nil))))
		     (bitneg (value)
			     (if (and widen (= (expr-width expr) source-bits))
				 (if (eq mode :sex)
				     (make-expr :kind (expr-kind expr) :type (expr-type expr) :width target-bits
						:operands (list (convert value t :sex)))
				     (make-expr :kind 'zex :type (expr-type expr) :width target-bits
						:operands (list (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
									   :operands (list (convert value nil))))))
				 (make-expr :kind (expr-kind expr) :type (expr-kind expr) :width (expr-width expr)
					    :operands (list (convert value nil)))))
		     ((+ - *) (op1 op2)
		      (if (and widen (= (expr-width expr) source-bits))
			  (if (eq mode :brutal)
			      (make-expr :kind (expr-kind expr) :type (expr-type expr) :width target-bits
					 :operands (list (convert op1 t :brutal) (convert op2 t :brutal)))
			      (make-expr :kind (if (eq mode :sex) 'sex zex) :type (expr-type expr) :width target-bits
					 :operands (list (make-expr :kind (expr-kind expr) :type (expr-type expr) :width source-bits
								    :operands (list (convert op1 nil) (convert op2 nil))))))
			  (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
				     :operands (list (convert op1 nil) (convert op2 nil)))))
		     ((shiftl shiftr rotl mask) (op1 op2)
		      (if (and widen (= (expr-width expr) source-bits))
			  (make-expr :kind (if (eq mode :sex) 'sex zex) :type (expr-type expr) :width target-bits
				     :operands (list (make-expr :kind (expr-kind expr) :type (expr-type expr) :width source-bits
								:operands (list (convert op1 nil) (convert op2 nil)))))
			  (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
				     :operands (list (convert op1 nil) (convert op2 nil)))))
		     ((logand logor logxor) (op1 op2)
		      (if (and widen (= (expr-width expr) source-bits))
			  (make-expr :kind (expr-kind expr) :type (expr-type expr) :width target-bits
				     :operands (list (convert op1 t mode) (convert op2 t mode)))
			  (make-expr :kind (expr-kind expr) :type (expr-type expr) :width (expr-width expr)
				     :operands (list (convert op1 nil) (convert op2 nil)))))
		     (= (op1 op2)
			(make-expr :kind '= :type (expr-type expr) :width target-bits
				   :operands (list (convert op1 nil) (convert op2 nil))))
		     (field (name begin end)
			    expr)))))
      (convert expr t))))

(defun disassemble-insn (insn)
  (labels ((find-directives (str &optional (start 0))
	     (let ((pos (position #\% str :start start)))
	       (if (null pos)
		   nil
		   (let* ((c (elt str (1+ pos)))
			  (directive (case c
				       ((#\x #\u) 'unsigned)
				       (#\d 'signed)
				       (#\s 'string)
				       (t (error "unknown directive %~A~%" c)))))
		     (cons directive (find-directives str (+ pos 2))))))))
    (let* ((format-string (car (insn-asm insn)))
	   (args (cdr (insn-asm insn)))
	   (directives (find-directives format-string))
	   (c-exprs (mapcar #'(lambda (directive expr)
				(case directive
				  (unsigned (generate-expr-code `(width ,(machine-word-bits *this-machine*) (zex ,expr))))
				  (signed (generate-expr-code `(width ,(machine-word-bits *this-machine*) (sex ,expr))))
				  (string (generate-expr-code expr nil nil))
				  (t (error "unknown directive ~A~%" directive))))
			    directives args)))
      (format t "printf(\"~A\"~{, ~A~});~%" format-string c-exprs))))

(defun generate-insn-recognizer (tree action)
  (if (insn-p tree)
      (progn
	(format t "/* ~A */~%" (insn-name tree) (insn-name tree))
	(format t "assert((insn & 0x~X) == 0x~X);~%" (bit-vector-to-integer (insn-known-bits tree)) (bit-vector-to-integer (insn-known-bit-values tree)))
	(funcall action tree))
      (let ((begin (caar tree))
	    (end (cdar tree))
	    (subtrees (cdr tree)))
	(format t "switch (~A) {~%" (code-for-field "insn" begin end))
	(dolist (subtree subtrees)
	  (format t "case ~A:~%" (car subtree))
	  (generate-insn-recognizer (cdr subtree) action)
	  (format t "break;~%"))
	(format t "default:~%assert(0);~%}~%"))))

(defun generate-interpreter-file (machine)
  (let ((*this-machine* machine))
    (with-open-file (out (format nil "~A_interpreter.c" (dcs (machine-name machine))) :direction :output :if-exists :supersede)
      (let ((*standard-output* out)
	    (decision-tree (build-decision-tree (machine-insns machine))))
	(format t "void interpret_~A_insn (interpreter_t *intp) {~%~A insn = mem_get_32(intp, intp->pc);~%word_32 pc = intp->pc, next_pc = pc + ~A;~%"
		(dcs (machine-name machine)) (c-type (machine-insn-bits *this-machine*) 'integer) (/ (machine-insn-bits *this-machine*) 8))
	(generate-insn-recognizer decision-tree #'(lambda (insn)
						    (when (contains-jump-p (insn-effect insn))
						      (format t "intp->have_jumped = 1;~%"))
						    (generate-code-for-insn insn)))
	(format t "intp->pc = next_pc;~%++intp->insn_count;~%}~%")
	(format t "void dump_~A_registers (interpreter_t *intp) {~%" (dcs (machine-name machine)))
	(dolist (reg (reverse (machine-registers machine)))
	  (let* ((class (register-register-class reg))
		 (name (register-name reg))
		 (class-name (register-class-name class))
		 (number (register-number reg)))
	    (if (eq (register-class-type class) 'float)
		(format t "printf(\"~A: 0x%lx (%f)\\n\", *(word_64*)&intp->regs_~A[~A], intp->regs_~A[~A]);~%"
			name class-name number class-name number)
		(format t "printf(\"~A: 0x%x\\n\", intp->regs_~A[~A]);~%"
			name class-name number))))
	(format t "printf(\"PC: 0x%x\\n\", intp->pc);~%}~%")))))
    
(defun generate-disassembler-file (machine)
  (let ((*this-machine* machine))
    (with-open-file (out (format nil "~A_disassembler.c" (dcs (machine-name machine))) :direction :output :if-exists :supersede)
      (let ((*standard-output* out)
	    (decision-tree (build-decision-tree (machine-insns machine))))
	(format t "void disassemble_~A_insn (~A insn, ~A addr) {~%"
		(dcs (machine-name machine)) (c-type (machine-insn-bits *this-machine*) 'integer) (c-type (machine-word-bits *this-machine*) 'integer))
	(generate-insn-recognizer decision-tree #'disassemble-insn)
	(format t "}~%")))))

(defun generate-compiler-file (machine)
  (let ((*this-machine* machine))
    (with-open-file (out (format nil "~A_compiler.c" (dcs (machine-name machine))) :direction :output :if-exists :supersede)
      (let ((*standard-output* out)
	    (decision-tree (build-decision-tree (machine-insns machine))))
	(format t "#define SCRATCH_OFFSET   ~A~%" (* 8 (length (machine-registers machine))))
	(format t "void move_~A_regs_interpreter_to_compiler (interpreter_t *intp) {~%" (dcs (machine-name machine)))
	(dolist (reg (machine-registers machine))
	  (let* ((class (register-register-class reg))
		 (width (register-class-width class))
		 (type (register-class-type class)))
	    (format t "*(~A*)&constant_area[~A * 2] = ~A;~%"
		    (c-type width type) (register-index reg class nil)
		    (generate-interpreter (make-expr :kind 'register :type type :width width
						     :operands (list reg class (register-number-expr reg))) nil))))
	(format t "}~%void move_~A_regs_compiler_to_interpreter (interpreter_t *intp) {~%" (dcs (machine-name machine)))
	(dolist (reg (machine-registers machine))
	  (let* ((class (register-register-class reg))
		 (width (register-class-width class))
		 (type (register-class-type class)))
	    (format t "~A = *(~A*)&constant_area[~A * 2];~%"
		    (generate-interpreter (make-expr :kind 'register :type type :width width :operands (list reg class (register-number-expr reg))) nil)
		    (c-type width type) (register-index reg class nil))))
	(format t "}~%void compile_~A_insn (~A insn, ~A pc) {~%"
		(dcs (machine-name machine)) (c-type (machine-insn-bits *this-machine*) 'integer) (c-type (machine-word-bits *this-machine*) 'integer))
	(generate-insn-recognizer decision-tree #'(lambda (insn)
						    (dolist (expr (insn-effect insn))
						      (princ (generate-compiler nil expr nil)))
						    (format t "generated_insn_index = ~A;~%" (position insn (machine-insns machine)))))
	(format t "~%#ifdef COLLECT_STATS~%++num_translated_insns;~%#endif~%}~%")
	(format t "char *insn_names[] = { ~{\"~A\"~^, ~} };~%" (mapcar #'insn-name (machine-insns machine)))))))

(defun generate-defines-file (machine)
  (let ((*this-machine* machine))
    (with-open-file (out (format nil "~A_defines.h" (dcs (machine-name machine))) :direction :output :if-exists :supersede)
      (let ((*standard-output* out))
	(format t "typedef ~A ~A_word;~%" (c-type (machine-word-bits *this-machine*) 'integer) (dcs (machine-name machine)))
	(format t "#define NUM_~A_REGISTERS ~A~%" (machine-name machine) (length (machine-registers machine)))
	(format t "#define NUM_INSNS ~A~%" (length (machine-insns machine)))
	(format t "#define ~A_REGISTER_SET" (machine-name machine))
	(dolist (class (machine-register-classes machine))
	  (let ((type (c-type (register-class-width class) (register-class-type class))))
	    (format t " ~A regs_~A[~A];" type (register-class-name class) (length (remove-if-not #'(lambda (reg)
												     (eq (register-register-class reg) class))
												 (machine-registers machine))))))
	(format t "~%")))))

(defun generate-composer-file (machine &key (safe t))
  (let ((*this-machine* machine))
    (with-open-file (out (format nil "~A_composer.h" (dcs (machine-name machine))) :direction :output :if-exists :supersede)
      (let ((*standard-output* out))
	(dolist (insn (reverse (machine-insns machine)))
	  (let* ((name (insn-name insn))
		 (known-bits (insn-known-bits insn))
		 (dont-care-bits (insn-dont-care-bits insn))
		 (non-operand-bits (bit-ior known-bits dont-care-bits))
		 (operands (mapcar #'(lambda (o) (cons o (substitute #\_ #\- (symbol-name o)))) (insn-operands insn))))
	    (format t "#define COMPOSE_~A(~{~A~^,~}) " name (mapcar #'cdr operands))
	    (when safe
	      (format t "({ ")
	      (dolist (operand operands)
		(multiple-value-bind (begin end)
		    (lookup-field (car operand))
		  (let ((c-name (cdr operand))
			(width (1+ (- end begin))))
		    (format t "assert((~A) >= 0 && (~A) < ~A); " c-name c-name (expt 2 width))))))
	    (format t "0x~X" (bit-vector-to-integer (insn-known-bit-values insn)))
	    (dolist (operand operands)
	      (multiple-value-bind (begin end)
		  (lookup-field (car operand))
		(let ((c-name (cdr operand)))
		  (format t " | ((~A) << ~A)" c-name begin))))
	    (dolist (equiv (insn-field-equivalences insn))
	      (destructuring-bind (field-name . operand-name)
		  equiv
		(multiple-value-bind (begin end)
		    (lookup-field field-name)
		  (let ((c-name (cdr (assoc operand-name operands))))
		    (format t " | ((~A) << ~A)" c-name begin)))))
	    (if safe
		(format t "; })~%")
		(format t "~%"))))
	(dolist (mnemonic (reverse (machine-mnemonics machine)))
	  (format t "#define COMPOSE_~A(~{~A~^,~}) COMPOSE_~A(~{~A~^,~})~%"
		  (mnemonic-name mnemonic) (mnemonic-args mnemonic)
		  (car (mnemonic-substitution mnemonic)) (cdr (mnemonic-substitution mnemonic))))))))