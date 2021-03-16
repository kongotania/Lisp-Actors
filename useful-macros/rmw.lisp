;; rmw.lisp -- Read/Modify/Write for general places
;;
;; Lock-free, ABA hazard-free, guaranteed mutation in SMP
;;
;; DM/RAL  11/20
;; -----------------------------------------------------------
(in-package :um)
;; ----------------------------------------------------------
;; To overcome the RMW ABA-Problem...
;;
;; We need to guard against ABA hazards during RMW. So we perform RMW
;; with a 2-phase protocol: First acquire its value, while marking
;; place as in-progress for update. The marking is done with a
;; descriptor that enables any thread to help toward completion if we
;; get interrupted. Then carry out the computation of the new value
;; and perform the update, if it hasn't already been done by anther
;; thread on our behalf. This protocol requires two CAS operations.
;;
;; We can no longer simply read nor write the value in a shared
;; location.  It might be in a state that is being updated by another
;; thread. If so, we nudge it along to final resolution before
;; acquiring/setting its value.
;;
;; As long as all modofiations to place are performed with WR or RMW
;; then we can be assured that there will be no ABA hazards. Reading
;; of place should be performed with RD, which helps push along any
;; update in progress before returning its stable value.
;;
;; Mutations performed with WR and RMW force all pending reads/writes
;; to be completed, and ensures cache coherency with other cores by
;; invalidating their cache lines for mutated place.
;;
;; ----------------------------------------------------------------
;; Assured lock-free, ABA hazard immune, mutation
;;
;; We need two primitives for every class of object:
;;  (BASIC-VAL obj) - returns the value contained in obj at this moment.
;;  (BASIC-CAS obj old new) - accomplishes a CAS on obj, returning T/F.
;;
;; We can't really know what value is held in obj for any length of
;; time after our mutation of it.  Another thread could come along and
;; mutate right after we did.  So we break precedent with SETF and
;; don't bother returning what we just set it to. When you need to
;; know what value is held in obj, perform a RD on it to get the value
;; it had at the time of the RD call.

;; ---------------------------------------------
;; This version uses a 2-phase approach, where competing threads help
;; complete an attempt in progress before launching their own.
;;
;; It has a theoretically bounded number of CAS attempts (= N+1) for N
;; competing threads. If a thread cannot complete, another thread will
;; do so for it.
(defstruct rmw-desc
  ;; contains captured old value, and mutator function
  ;;
  ;; WARNING! Mutator function can be called on any thread, and called
  ;; concurrently. It must be side-effect free, and idempotent.
  old new-fn)

(defgeneric rd-object   (obj))
(defgeneric wr-object   (obj new))
(defgeneric rmw-object  (obj new-fn))
(defgeneric cas-object  (obj old new))
(defgeneric atomic-exch-object (obj new))
(defgeneric atomic-incf-object (obj))
(defgeneric atomic-decf-object (obj))

;; ------------------------------------------------------------------

(defvar *rmw-tbl* (make-hash-table)) ;; compiler support table

(defmacro gen-rmw-funcs (place)
  (flet ((gen-name (kind &optional (placer (car place)))
           (intern (format nil "~A-~A"
                           (string kind)
                           (string placer))
                   )))
    (lw:with-unique-names (obj ix v new new-fn desc old again)
      (let* (type
             (deftype     'defun)
             rd-name
             (rd-args     `(,obj))
             wr-name
             (wr-args     `(,obj ,new))
             rmw-name
             (rmw-args    `(,obj ,new-fn))
             accessor
             (cas-fn      'sys:compare-and-swap)
             cas-accessor
             (exch-fn     'sys:atomic-exchange)
             cas-name
             exch-name
             incf-name
             decf-name
             (incf-fn     'sys:atomic-incf)
             (decf-fn     'sys:atomic-decf)
             extra-defs)
        
        (ecase (car place)
          #|
          ((object)
           (setf accessor     `(basic-val ,obj)
                 cas-fn       'basic-cas
                 cas-accessor obj
                 exch-fn      `basic-atomic-exch
                 deftype      'defmethod
                 incf-fn      'basic-atomic-incf
                 decf-fn      'basic-atomic-decf))
          |#
          ((car)
           (setf type         'cons
                 accessor     `(car ,obj)))
          ((cdr)
           (setf type         'cons
                 accessor     `(cdr ,obj)))
          ((symbol-value)
           (setf type         'symbol
                 accessor     `(symbol-value ,obj)))
          ((svref)
           (setf type         'simple-vector
                 rd-args      `(,obj ,ix)
                 wr-args      `(,obj ,ix ,new)
                 rmw-args     `(,obj ,ix ,new-fn)
                 accessor     `(svref ,obj ,ix)))
          ((struct)
           (destructuring-bind (_ struct-name accessor-fn) place
             (declare (ignore _))
             (setf type       struct-name
                   rd-name    (gen-name :rd  accessor-fn)
                   wr-name    (gen-name :wr  accessor-fn)
                   rmw-name   (gen-name :rmw accessor-fn)
                   cas-name   (gen-name :cas accessor-fn)
                   exch-name  (gen-name :atomic-exch accessor-fn)
                   incf-name  (gen-name :atomic-incf accessor-fn)
                   decf-name  (gen-name :atomic-decf accessor-fn)
                   accessor   `(,accessor-fn ,obj)
                   #|
                   ;; It is probably wrong to assume that the entire
                   ;; object wants to be ruled by one slot. If so, let
                   ;; the constructor of the object supply additional
                   ;; methods.
                   extra-defs `((defmethod rd-object ((,obj ,struct-name))
                                  (,rd-name ,obj))
                                (defmethod wr-object ((,obj ,struct-name) ,new)
                                  (,wr-name ,obj ,new))
                                (defmethod rmw-object ((,obj ,struct-name) ,new-fn)
                                  (,rmw-name ,obj ,new-fn))
                                (defmethod cas-object ((,obj ,struct-name) ,old ,new)
                                  (,cas-name ,obj ,old ,new))
                                (defmethod atomic-exch-object ((,obj ,struct-name) ,new)
                                  (,exch-name ,obj ,new))
                                (defmethod atomic-incf-object ((,obj ,struct-name))
                                  (,incf-name ,obj))
                                (defmethod atomic-decf-object ((,obj ,struct-name))
                                  (,decf-name ,obj)))
                   |#
                   ))))
        
        (macrolet ((set-default (sym form)
                     `(unless ,sym
                        (setf ,sym ,form))))
          (set-default rd-name      (gen-name :rd))
          (set-default wr-name      (gen-name :wr))
          (set-default rmw-name     (gen-name :rmw))
          (set-default cas-name     (gen-name :cas))
          (set-default exch-name    (gen-name :atomic-exch))
          (set-default incf-name    (gen-name :atomic-incf))
          (set-default decf-name    (gen-name :atomic-decf))
          (set-default cas-accessor accessor))

        #|
        (setf (gethash (car accessor) *rmw-tbl*)
              (list rd-name wr-name rmw-name))
        |#
        
        ;; Same basic structure to all versions, so define the logic
        ;; in just one place...
        `(progn
           (export '(,rd-name ,wr-name ,rmw-name ,cas-name
                              ,exch-name ,incf-name ,decf-name))
           (setf (gethash ',(car accessor) *rmw-tbl*)
                 (list ',rd-name ',wr-name ',rmw-name ',cas-name
                       ',exch-name ',incf-name ',decf-name))
           
           (,deftype ,rd-name ,rd-args
             #F
             ,@(when type
                 `((declare (,type ,obj))))
             (prog ()
               ,again
               (let ((,v ,accessor))
                 (cond ((rmw-desc-p ,v)
                        (let ((,new (funcall (rmw-desc-new-fn ,v) (rmw-desc-old ,v))))
                          (if (,cas-fn ,cas-accessor ,v ,new)
                              (return ,new)
                            (go ,again))
                          ))
                       (t
                        (return ,v))
                       ))))
           
           (,deftype ,wr-name ,wr-args
             #F
             ,@(when type
                 `((declare (,type ,obj))))
             ;; this gives a compiler error for unused result
             ;;   (,exch-fn ,cas-accessor ,new)
             ;;   ,new
             #|
             (or (and (,exch-fn ,cas-accessor ,new)
                      ,new)
                 ,new)
             |#
             (setf (sys:globally-accessible ,accessor) ,new))
           
           (,deftype ,rmw-name ,rmw-args
             #F
             ,@(when type
                 `((declare (,type ,obj))))
             (let ((,desc (make-rmw-desc
                           :new-fn ,new-fn)))
               (prog ()
                 ,again
                 (let ((,old (,rd-name ,@rd-args)))
                   (setf (rmw-desc-old ,desc) ,old)
                   (if (,cas-fn ,cas-accessor ,old ,desc)
                       (,cas-fn ,cas-accessor ,desc (funcall ,new-fn ,old))
                     (go ,again))
                   ))))

           (,deftype ,cas-name (,@rd-args ,old ,new)
              #F
              ,@(when type
                  `((declare (,type ,obj))))
              (,cas-fn ,cas-accessor ,old ,new))

           (,deftype ,exch-name (,@rd-args ,new)
              #F
              ,@(when type
                  `((declare (,type ,obj))))
              (,exch-fn ,cas-accessor ,new))

           (,deftype ,incf-name ,rd-args
             #F
             ,@(when type
                 `((declare (,type ,obj))))
             (,incf-fn ,cas-accessor))
           
           (,deftype ,decf-name ,rd-args
             #F
             ,@(when type
                 `((declare (,type ,obj))))
             (,decf-fn ,cas-accessor))
           
           ,@extra-defs)
        ))))

(defmacro gen-struct-rmw-funcs (struct-name accessor-fn)
  `(gen-rmw-funcs (struct ,struct-name ,accessor-fn)))

(progn
  ;; (gen-rmw-funcs (object))
  (gen-rmw-funcs (car obj))
  (gen-rmw-funcs (cdr obj))
  (gen-rmw-funcs (symbol-value obj))
  (gen-rmw-funcs (svref obj ix)))

;; -----------------------------------------------------------------

(defmacro rd (place)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(first fns) ,obj ,@args)
               `(rd-object ,place))
             )))
        (t
         `(rd-object ,place))
        ))

(defmacro wr (place new)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(second fns) ,obj ,@args ,new)
               `(wr-object ,place ,new))
             )))
        (t
         `(wr-object ,place ,new))
        ))

(defmacro rmw (place new-fn)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(third fns) ,obj ,@args ,new-fn)
               `(rmw-object ,place ,new-fn))
             )))
        (t
         `(rmw-object ,place ,new-fn))
        ))

(defmacro cas (place old new)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(fourth fns) ,obj ,@args ,old ,new)
               `(cas-object ,place ,old ,new))
             )))
        (t
         `(cas-object ,place ,old ,new))
        ))

(defmacro atomic-exch (place new)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(fifth fns) ,obj ,@args ,new)
               `(atomic-exch-object ,place ,new))
             )))
        (t
         `(atomic-exch-object ,place ,new))
        ))

(defmacro atomic-incf (place)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(sixth fns) ,obj ,@args)
               `(atomic-incf-object ,place))
             )))
        (t
         `(atomic-incf-object ,place))
        ))

(defmacro atomic-decf (place)
  (cond ((consp place)
         (destructuring-bind (placer obj &rest args) place
           (let ((fns (gethash placer *rmw-tbl*)))
             (if fns
                 `(,(seventh fns) ,obj ,@args)
               `(atomic-decf-object ,place))
             )))
        (t
         `(atomic-decf-object ,place))
        ))



