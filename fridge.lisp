(defpackage :fridge
  (:use :common-lisp :postmodern :closer-mop :versioned-objects)
  (:export :load-instance
	   :load-instances
	   :save
	   :delete-instance
	   :db=

	   :record-not-found-error
	   :inconsistent-database-error))

(defpackage :fridge-user
  (:use :common-lisp :fridge))

(in-package :fridge)
(declaim (optimize (speed 0) (safety 3) (debug 3)))

(defconstant +db-snapshot+ '+db-snapshot+ "Snapshot of the state of the object in the database")

(defgeneric load-instance (class &key &allow-other-keys)
  (:documentation "Loads an object, its superclasses and its subclasses from the database.
The order in which the objects are loaded is unspecified."))
(defgeneric load-instances (class &key &allow-other-keys)
  (:documentation "Loads a series of objects matching the given initargs, their superclasses and their subclasses from the database.
The order in which the objects are loaded internally and externally, is unspecified.
If no objects in the database match the initargs, the empty list is returned."))
(defgeneric save (object)
  (:documentation "Updates the correct row(s) in the database, so it represents the values that are currently set."))
(defgeneric delete-instance (object)
  (:documentation "Removes the rows from the database that represented this object."))
(defgeneric db= (a &rest args)
  (:documentation "Wether or not the objects have the same state in the database.  It assumes that the objects have been loaded from the database and will not reload them.  This effectively allows you to test if an object would receive another state in the database."))

(defgeneric find-slot-name-by-column (class column-name)
  (:documentation "Finds the slot name that is related to the given column name for the given class"))
(defgeneric find-column-by-initarg (class initarg)
  (:documentation "Finds the column that is specified by the given initarg"))
(defgeneric find-slot-by-initarg (class initarg)
  (:documentation "Finds the slot that has the given initarg."))
(defgeneric object-in-database-p (object)
  (:documentation "Whether or not <object> has a database representation (which may be out-of-date)"))
(defgeneric object-up-to-date-p (object)
  (:documentation "Whether or not <object> has changed its representation since its last load or save.  If the object has no known database-representation, nil is returned."))
(defgeneric object-updated-database-state (object)
  (:documentation "A plist of the columns and their values within the object, which represents the state the object currently has with respect to the database."))
(defgeneric object-current-database-state (object)
  (:documentation " A plist of the colemns and their values within the object, which represents the last known state the object had in the database.  This is the state it had its last load or save."))


(defclass column-slot-connection ()
  ((slot-name :accessor slot-name
	      :initarg :slot-name
	      :documentation "The name of the slot in the class")
   (column-name :accessor column-name
		:initarg :column-name
		:documentation "The name of the slot in the database"))
  (:documentation "Contains the needed information to connect a database column to a slot. Does not contain the database table name."))

(defclass db-support-metaclass (standard-class)
  ((database-slots :initform nil
		   :initarg :database-slots
		   :accessor database-slots)
   (database-table :initarg :database-table
		   :accessor database-table))
  (:documentation "This is the most basic form of a class that has access to the database.  There are a range of slots that have a database backing. The slots must be specified manually and can be set/retrieved through save and load.

eg: (defclass user ()
      ((name :column :name
             :initarg :name
             :accessor :name)
       (email :column :email-address
              :initarg :email
              :accessor email))
      (:table :users)
      (:metaclass db-support-metaclass))"))

(flet ((set-args (db-support-class &rest args &key table direct-slots &allow-other-keys)
	 (declare (ignore args))
	 (when table
	   (setf (database-table db-support-class) (first table)))
	 (setf (database-slots db-support-class)
	       (loop for slot-definition in direct-slots
		  as column = (getf slot-definition :column)
		  when column 
		  collect (make-instance 'column-slot-connection 
					 :slot-name (getf slot-definition :name)
					 :column-name column)))))
  (defmethod initialize-instance :after ((dbm db-support-metaclass) &rest args &key &allow-other-keys)
    (apply #'set-args dbm args))
  (defmethod reinitialize-instance :after ((dbm db-support-metaclass) &rest args &key &allow-other-keys)
    (apply #'set-args dbm args)))


;;;; BEGIN relaxing the rules on what may be defined in defclass
(defmethod closer-mop:validate-superclass ((a db-support-metaclass) (b standard-class))
  T)

(defclass db-support-effective-slot (standard-effective-slot-definition) ())
(defclass db-support-direct-slot (standard-direct-slot-definition) ())

(defmethod effective-slot-definition-class ((class db-support-metaclass) &rest args)
  (declare (ignore args))
  (find-class 'db-support-effective-slot))
(defmethod direct-slot-definition-class ((class db-support-metaclass) &rest args)
  (declare (ignore args))
  (find-class 'db-support-direct-slot))

(defmacro method-allow-other-keys (name &rest args)
  `(defmethod ,name :before (,@args &rest args &key &allow-other-keys)
     (declare (ignore args))))
(method-allow-other-keys initialize-instance (class db-support-metaclass))
(method-allow-other-keys make-instance (slot db-support-effective-slot))
(method-allow-other-keys make-instance (slot db-support-direct-slot))
(method-allow-other-keys make-instance (class db-support-metaclass))
(method-allow-other-keys initialize-instance (slot db-support-effective-slot))
(method-allow-other-keys initialize-instance (slot db-support-direct-slot))

;;;; END relaxing the rules on what may be defined in defclass

(defclass db-support-class (versioned-object)
  () 
  (:metaclass db-support-metaclass)
  (:documentation "It is best to make this the superclass of your db-support-metaclass metaclassed classes."))

(defmethod db= ((object db-support-class) &rest args)
  (loop for a in (cons object args)
     for b in args
     when (not (equalp (object-updated-database-state a)
		       (object-updated-database-state b)))
     do (return-from db= nil))
  T)

(defmethod object-in-database-p ((object db-support-class))
  (snapshot-p object +db-snapshot+))

(defmethod object-up-to-date-p ((object db-support-class))
  (and (object-in-database-p object)
       (not (changed-p object +db-snapshot+))))

(defmethod object-updated-database-state ((object db-support-class))
  (loop for connection in (database-slots (class-of object))
     append (list (column-name connection)
		  (slot-value object (slot-name connection)))))
(defmethod object-current-database-state ((object db-support-class))
  (when (object-in-database-p object) 
    (loop for connection in (database-slots (class-of object))
       append (list (column-name connection)
		    (snapshot-value object +db-snapshot+ (slot-name connection))))))

(defmethod find-slot-by-initarg ((class standard-class) (initarg symbol))
  (flet ((slot-has-initarg-p (slot initarg)
	   (find initarg (slot-value slot 'sb-pcl::initargs))))
    (find-if (lambda (slot) (slot-has-initarg-p slot initarg))
	     (slot-value class 'sb-pcl::direct-slots))))

(defmethod find-column-by-initarg ((class db-support-metaclass) (initarg symbol))
  (let ((slot (find-slot-by-initarg class initarg)))
    (column-name (find-if (lambda (database-slot)
			       (eql (slot-name database-slot) (slot-value slot 'sb-pcl::name)))
			     (database-slots class)))))

(defmethod find-slot-name-by-column ((class db-support-metaclass) (column symbol))
  (slot-name (find column
		   (database-slots class)
		   :key #'column-name)))

(define-condition record-not-found-error (error)
  ((db-table :initarg :table :reader db-table)
   (where :initarg :where :reader where-clause)
   (query :initarg :query :reader db-query))
  (:documentation "This error is thrown when a certain record could not be found.  This can happen whilst trying to load a certain instance."))

(defun get-query-alist (query)
  (let ((query-result (query (sql-compile query) :alists)))
    (restart-case (unless query-result
		    (error 'record-not-found-error :query query))
      (provide-alist (alist) (return-from get-query-alist alist))
      (retry () (get-query-alist query)))
    query-result))
(defgeneric and-query-from-initargs (class &rest initargs)
  (:documentation "Returns an s-sql and-query that represents the way the initargs would be interpreted in the database"))
(defmethod and-query-from-initargs ((class symbol) &rest initargs)
  (apply #'and-query-from-initargs (find-class class) initargs))
(defmethod and-query-from-initargs ((class db-support-metaclass) &rest initargs)
  (let ((initcolumns (loop for initarg on initargs by #'cddr append
			  (list (find-column-by-initarg class (first initarg)) (second initarg)))))
    (cons :and
	  (loop for initcol on initcolumns by #'cddr collect
	       (list := (first initcol) (second initcol))))))
(defgeneric set-slots-from-column-alist (class object &rest column-alist)
  (:documentation "Sets the slot-values from the given column alist. After setting the slots, the snapshot is set to the current values in the object."))
(defmethod set-slots-from-column-alist ((class db-support-metaclass) (object db-support-class) &rest column-alist)
  (loop for (column-name . value) in column-alist
     do (setf (slot-value object (find-slot-name-by-column (class-of object) column-name)) value))
  (snapshot object +db-snapshot+)
  object)
(defmethod load-instance ((class symbol) &rest initargs)
  (apply #'load-instance (find-class class) initargs))
(defmethod load-instance ((class db-support-metaclass) &rest initargs)
  (let* ((complete-query (list :select '* :from (database-table class) :where (apply #'and-query-from-initargs class initargs)))
	 (object (apply #'make-instance class initargs)))
    (apply #'set-slots-from-column-alist class object (first (get-query-alist complete-query)))))

(defmethod load-instances ((class symbol) &rest initargs)
  (apply #'load-instances (find-class class) initargs))
(defmethod load-instances ((class db-support-metaclass) &rest initargs)
  (let* ((complete-query (list :select '* :from (database-table class) :where (apply #'and-query-from-initargs class initargs))))
    (handler-case (loop for alist in (get-query-alist complete-query)
		     collect (apply #'set-slots-from-column-alist class (apply #'make-instance class initargs) alist))
      (record-not-found-error () nil))))

(define-condition inconsistent-database-error (error)
  ((object :initarg :object :reader object)
   (where :initarg :where :reader where-clause)
   (set :initarg :set :reader set-clause :initform nil))
  (:documentation "Error that will be thrown when an action can not be fulfilled due to a changed database schema."))

(defmethod save ((object db-support-class))
  (let ((set-clause (object-updated-database-state object)))
    (unless (and (object-in-database-p object)
		 (object-up-to-date-p object))
      ;; we need to save our inner class
      (flet ((update-database (object set &optional where)
	       (restart-case
		   (multiple-value-bind (something updated-rows)
		       (if where
			   (query (sql-compile `(:update ,(database-table (class-of object)) :set ,@set :where ,where)))
			   (query (sql-compile `(:insert-into ,(database-table (class-of object)) :set ,@set))))
		     (declare (ignore something))
		     (unless (= 1 updated-rows)
		       (error 'inconsistent-database-error :object object :where where :set set)))
		 (pretend-database-model-has-been-updated () nil))))
	(cond ((and (object-in-database-p object) (not (object-up-to-date-p object)))
	       (let ((where-clause (cons :and 
					 (loop for (column value) on (object-current-database-state object) by #'cddr
					    collect (list := column value)))))
		 (update-database object set-clause where-clause)))
	      ((not (object-in-database-p object))
	       (update-database object set-clause)))))
    (snapshot object +db-snapshot+)
    object))

(defmethod delete-instance ((object db-support-class))
  (let* ((where-clause `(:and ,@(loop for (column value) on (object-current-database-state object) by #'cddr
				   collect (list := column value))))
	 (query `(:delete-from ,(database-table (class-of object)) :where ,where-clause)))
    (multiple-value-bind (unimportant updated-rows)
	(query (sql-compile query))
      (declare (ignore unimportant))
      (restart-case (progn 
		      (unless (> updated-rows 0)
			(error 'record-not-found-error
			       :table (database-table (class-of object))
			       :where where-clause
			       :query query))
		      (rm-snapshot object +db-snapshot+))
	(retry () (delete-instance object))
	(continue () nil)))))
