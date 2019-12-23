;;; Copyright (C) 2018-2019 Sahil Kang <sahil.kang@asilaycomputing.com>
;;;
;;; This file is part of cl-rdkafka.
;;;
;;; cl-rdkafka is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; cl-rdkafka is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with cl-rdkafka.  If not, see <http://www.gnu.org/licenses/>.

(in-package #:cl-rdkafka)

(defclass consumer ()
  ((rd-kafka-consumer
    :documentation "Pointer to rd_kafka_t struct.")
   (rd-kafka-queue
    :documentation "Pointer to rd_kafka_queue_t struct.")
   (key-serde
    :type deserializer
    :documentation "Deserializer to map byte vector to object.")
   (value-serde
    :type deserializer
    :documentation "Deserializer to map byte vector to object."))
  (:documentation
   "A client that consumes messages from kafka topics.

Example:

(let ((consumer (make-instance
                 'kf:consumer
                 :conf '(\"bootstrap.servers\" \"127.0.0.1:9092\"
                         \"group.id\" \"consumer-group-id\"
                         \"enable.auto.commit\" \"false\"
                         \"auto.offset.reset\" \"earliest\"
                         \"offset.store.method\" \"broker\"
                         \"enable.partition.eof\"  \"false\")
                 :serde (lambda (bytes)
                          (babel:octets-to-string bytes :encoding :utf-8)))))
  (kf:subscribe consumer '(\"topic-name\"))

  (loop
     for message = (kf:poll consumer 2000)
     while message

     for key = (kf:key message)
     for value = (kf:value message)

     collect (list key value)

     do (kf:commit consumer)))"))

(defgeneric subscribe (consumer topics))

(defgeneric unsubscribe (consumer)
  (:documentation
   "Unsubscribe consumer from its current topic subscription."))

(defgeneric subscription (consumer)
  (:documentation
   "Return a list of topic names that CONSUMER is subscribed to."))

(defgeneric poll (consumer timeout-ms)
  (:documentation
   "Block for up to timeout-ms milliseconds and return a kf:message or nil"))



(defgeneric commit (consumer &key offsets asyncp))

(defgeneric committed (consumer &optional topic+partitions)
  (:documentation
   "Return an alist of committed topic+partitions.

TOPIC+PARTITIONS is an alist with elements that look like:
  * (topic . partition)

If TOPIC+PARTITIONS is nil (the default) then info about the current
assignment is returned.

The returned alist has elements that look like:
  * ((topic . partition) . (offset . metadata))"))

(defgeneric assignment (consumer)
  (:documentation
   "Return an alist of assigned topic+partitions.

Each element of the returned alist will look like:
  * (topic . partition)"))

(defgeneric assign (consumer topic+partitions)
  (:documentation
   "Assign TOPIC+PARTITIONS to CONSUMER.

TOPIC+PARTITIONS is an alist with elements that look like:
  * (topic . partition)"))

(defgeneric member-id (consumer)
  (:documentation
   "Return CONSUMER's broker-assigned group member-id."))

(defgeneric pause (consumer topic+partitions)
  (:documentation
   "Pause consumption from the TOPIC+PARTITIONS alist."))

(defgeneric resume (consumer topic+partitions)
  (:documentation
   "Resume consumption from the TOPIC+PARTITIONS alist."))

(defgeneric query-watermark-offsets (consumer topic partition &key timeout-ms)
  (:documentation
   "Query broker for low (oldest/beginning) and high (newest/end) offsets.

A (low high) list is returned."))

(defgeneric offsets-for-times (consumer timestamps &key timeout-ms)
  (:documentation
   "Look up the offsets for the given partitions by timestamp.

The returned offset for each partition is the earliest offset whose
timestamp is greater than or equal to the given timestamp in the
corresponding partition.

TIMESTAMPS is an alist with elements that look like:
  ((\"topic\" . partition) . timestamp)

and the returned alist contains elements that look like:
  ((\"topic\" . partition) . offset)"))

(defgeneric positions (consumer topic+partitions)
  (:documentation
   "Retrieve current positions (offsets) for TOPIC+PARTITIONS.

TOPIC+PARTITIONS is an alist with elements that look like:
  (\"topic\" . partition)

and the returned alist contains elements that look like (offset will
be nil if no previous message existed):
  ((\"topic\" . partition) . offset)"))

(defgeneric close (consumer)
  (:documentation
   "Close CONSUMER after revoking assignment, committing offsets, and leaving group.

CONSUMER will be closed during garbage collection if it's still open;
this method is provided if closing needs to occur at a well-defined
time."))

(defun get-good-commits-and-assert-no-bad-commits (rd-kafka-event)
  (let (goodies baddies)
    (foreach-toppar
        (cl-rdkafka/ll:rd-kafka-event-topic-partition-list rd-kafka-event)
        (topic partition offset metadata metadata-size err)
      (let ((toppar (cons topic partition)))
        (if (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
            (let* ((meta (pointer->bytes metadata metadata-size))
                   (offset+meta (cons offset meta)))
              (push (cons toppar offset+meta) goodies))
            (let ((error-string (cl-rdkafka/ll:rd-kafka-err2str err)))
              (push (cons toppar error-string) baddies)))))
    (when baddies
      (error 'partial-error
             :description "Commit failed"
             :baddies (nreverse baddies)
             :goodies (nreverse goodies)))
    (nreverse goodies)))

(defun process-commit-event (rd-kafka-event queue)
  (assert-expected-event rd-kafka-event cl-rdkafka/ll:rd-kafka-event-offset-commit)
  (let ((err (cl-rdkafka/ll:rd-kafka-event-error rd-kafka-event))
        (promise (lparallel.queue:pop-queue queue)))
    (handler-case
        (cond
          ((eq err cl-rdkafka/ll:rd-kafka-resp-err--no-offset)
           (lparallel:fulfill promise))
          ((eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
           (lparallel:fulfill promise
             (get-good-commits-and-assert-no-bad-commits rd-kafka-event)))
          (t (error 'kafka-error
                    :description (cl-rdkafka/ll:rd-kafka-err2str err))))
      (condition (c)
        (lparallel:fulfill promise c)))))

(defun make-consumer-finalizer (rd-kafka-consumer rd-kafka-queue)
  (lambda ()
    (deregister-rd-kafka-queue rd-kafka-queue)
    (cl-rdkafka/ll:rd-kafka-queue-destroy rd-kafka-queue)
    (cl-rdkafka/ll:rd-kafka-destroy rd-kafka-consumer)))

(defmethod initialize-instance :after
    ((consumer consumer) &key conf (serde #'identity) key-serde value-serde)
  (with-slots (rd-kafka-consumer
               rd-kafka-queue
               (ks key-serde)
               (vs value-serde))
      consumer
    (with-conf rd-kafka-conf conf
      (cl-rdkafka/ll:rd-kafka-conf-set-events
       rd-kafka-conf
       cl-rdkafka/ll:rd-kafka-event-offset-commit)
      (cffi:with-foreign-object (errstr :char +errstr-len+)
        (setf rd-kafka-consumer (cl-rdkafka/ll:rd-kafka-new
                                 cl-rdkafka/ll:rd-kafka-consumer
                                 rd-kafka-conf
                                 errstr
                                 +errstr-len+))
        (when (cffi:null-pointer-p rd-kafka-consumer)
          (error 'allocation-error
                 :name "consumer"
                 :description (cffi:foreign-string-to-lisp
                               errstr :max-chars +errstr-len+)))))
    (setf rd-kafka-queue (cl-rdkafka/ll:rd-kafka-queue-new rd-kafka-consumer))
    (when (cffi:null-pointer-p rd-kafka-queue)
      (cl-rdkafka/ll:rd-kafka-destroy rd-kafka-consumer)
      (error 'allocation-error :name "queue"))
    (handler-case
        (register-rd-kafka-queue rd-kafka-queue #'process-commit-event)
      (condition (c)
        (cl-rdkafka/ll:rd-kafka-queue-destroy rd-kafka-queue)
        (cl-rdkafka/ll:rd-kafka-destroy rd-kafka-consumer)
        (error c)))
    (setf ks (make-instance 'deserializer
                            :name "key-serde"
                            :function (or key-serde serde))
          vs (make-instance 'deserializer
                            :name "value-serde"
                            :function (or value-serde serde)))
    (tg:finalize consumer (make-consumer-finalizer rd-kafka-consumer rd-kafka-queue))))

(defmethod subscribe ((consumer consumer) (topics sequence))
  "Subscribe CONSUMER to TOPICS.

Any topic prefixed with '^' will be regex-matched with the cluster's
topics."
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list toppar-list (alloc-toppar-list topics)
      (let ((err (cl-rdkafka/ll:rd-kafka-subscribe rd-kafka-consumer
                                                   toppar-list)))
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))))))

(defmethod subscribe ((consumer consumer) (topic string))
  "Subscribe CONSUMER to TOPIC.

If TOPIC starts with '^', then it will be regex-matched with the
cluster's topics."
  (subscribe consumer (list topic)))

(defmethod unsubscribe ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((err (cl-rdkafka/ll:rd-kafka-unsubscribe rd-kafka-consumer)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error 'kafka-error
               :description (cl-rdkafka/ll:rd-kafka-err2str err))))))

(defun %subscription (rd-kafka-consumer)
  (cffi:with-foreign-object (rd-list :pointer)
    (let ((err (cl-rdkafka/ll:rd-kafka-subscription
                rd-kafka-consumer
                rd-list)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error 'kafka-error
               :description (cl-rdkafka/ll:rd-kafka-err2str err)))
      (cffi:mem-ref rd-list :pointer))))

(defmethod subscription ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list toppar-list (%subscription rd-kafka-consumer)
      (let (return-me)
        (foreach-toppar toppar-list (topic)
          (push topic return-me))
        return-me))))

(defmethod poll ((consumer consumer) (timeout-ms integer))
  (with-slots (rd-kafka-consumer key-serde value-serde) consumer
    (let ((rd-kafka-message (cl-rdkafka/ll:rd-kafka-consumer-poll
                             rd-kafka-consumer
                             timeout-ms)))
      (unwind-protect
           (unless (cffi:null-pointer-p rd-kafka-message)
             (rd-kafka-message->message rd-kafka-message
                                        (lambda (bytes)
                                          (apply-serde key-serde bytes))
                                        (lambda (bytes)
                                          (apply-serde value-serde bytes))))
        (unless (cffi:null-pointer-p rd-kafka-message)
          (cl-rdkafka/ll:rd-kafka-message-destroy rd-kafka-message))))))

(defun %commit (rd-kafka-consumer toppar-list rd-kafka-queue)
  (let ((err (cl-rdkafka/ll:rd-kafka-commit-queue
              rd-kafka-consumer
              toppar-list
              rd-kafka-queue
              (cffi:null-pointer)
              (cffi:null-pointer))))
    (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
      (error 'kafka-error
             :description (cl-rdkafka/ll:rd-kafka-err2str err)))
    (let ((promise (lparallel:promise)))
      (enqueue-payload rd-kafka-queue promise)
      promise)))

(defmethod commit ((consumer consumer) &key offsets asyncp)
  "Commit OFFSETS to broker.

If OFFSETS is nil, then the current assignment is committed;
otherwise, OFFSETS should be an alist mapping (topic . partition) cons
cells to either (offset . metadata) cons cells or lone offset values.

On success, an alist of committed offsets is returned, mapping
(topic . partition) to (offset . metadata).

On failure, either a KAFKA-ERROR or PARTIAL-ERROR is signalled.
The PARTIAL-ERROR will have the slots:
  * GOODIES: Same format as successful return value
  * BADDIES: An alist mapping (topic . partition) to error strings

If ASYNCP is true, then a FUTURE will be returned instead."
  (with-slots (rd-kafka-consumer rd-kafka-queue) consumer
    (with-toppar-list
        toppar-list
        (if (null offsets)
            (cffi:null-pointer)
            (alloc-toppar-list offsets
                               :topic #'caar
                               :partition #'cdar
                               :offset (lambda (pair)
                                         (if (consp (cdr pair))
                                             (cadr pair)
                                             (cdr pair)))
                               :metadata (lambda (pair)
                                           (when (consp (cdr pair))
                                             (cddr pair)))))
      (let* ((promise (%commit rd-kafka-consumer toppar-list rd-kafka-queue))
             (future (make-instance 'future :promise promise :client consumer)))
        (if asyncp
            future
            (value future))))))

(defun %assignment (rd-kafka-consumer)
  (cffi:with-foreign-object (rd-list :pointer)
    (let ((err (cl-rdkafka/ll:rd-kafka-assignment rd-kafka-consumer rd-list)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error 'kafka-error
               :description (cl-rdkafka/ll:rd-kafka-err2str err)))
      (cffi:mem-ref rd-list :pointer))))

(defmethod assignment ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list toppar-list (%assignment rd-kafka-consumer)
      (let (alist-to-return)
        (foreach-toppar toppar-list (topic partition)
          (push (cons topic partition) alist-to-return))
        alist-to-return))))

(defmethod committed ((consumer consumer) &optional topic+partitions)
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list
        toppar-list
        (if topic+partitions
            (alloc-toppar-list topic+partitions :topic #'car :partition #'cdr)
            (%assignment rd-kafka-consumer))
      (let ((err (cl-rdkafka/ll:rd-kafka-committed
                  rd-kafka-consumer
                  toppar-list
                  60000))
            alist-to-return)
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))
        (foreach-toppar
            toppar-list
            (topic partition offset metadata metadata-size err)
          (let (skip-p)
            (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
              (cerror (format nil "Don't include `~A:~A` in the returned alist."
                              topic
                              partition)
                      'topic+partition-error
                      :description (cl-rdkafka/ll:rd-kafka-err2str err)
                      :topic topic
                      :partition partition)
              (setf skip-p t))
            (unless skip-p
              (let ((meta (unless (cffi:null-pointer-p metadata)
                            (pointer->bytes metadata metadata-size))))
                (push `((,topic . ,partition) . (,offset . ,meta))
                      alist-to-return)))))
        alist-to-return))))

(defmethod assign ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list
        toppar-list
        (alloc-toppar-list topic+partitions :topic #'car :partition #'cdr)
      (let ((err (cl-rdkafka/ll:rd-kafka-assign rd-kafka-consumer toppar-list)))
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))))))

(defmethod member-id ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (cl-rdkafka/ll:rd-kafka-memberid rd-kafka-consumer)))

(defmethod pause ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list
        toppar-list
        (alloc-toppar-list topic+partitions :topic #'car :partition #'cdr)
      (let ((err (cl-rdkafka/ll:rd-kafka-pause-partitions
                  rd-kafka-consumer
                  toppar-list)))
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))
        ;; rd-kafka-pause-partitions will set the err field of
        ;; each struct in rd-list, so let's make sure no per
        ;; topic-partition errors occurred
        (foreach-toppar toppar-list (err topic partition)
          (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
            (cerror "Continue checking pause status of other topic+partitions."
                    'topic+partition-error
                    :description (cl-rdkafka/ll:rd-kafka-err2str err)
                    :topic topic
                    :partition partition)))))))

(defmethod resume ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list
        toppar-list
        (alloc-toppar-list topic+partitions :topic #'car :partition #'cdr)
      (let ((err (cl-rdkafka/ll:rd-kafka-resume-partitions
                  rd-kafka-consumer
                  toppar-list)))
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))
        (foreach-toppar toppar-list (err topic partition)
          (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
            (cerror "Continue checking resume status of other topic+partitions."
                    'topic+partition-error
                    :description (cl-rdkafka/ll:rd-kafka-err2str err)
                    :topic topic
                    :partition partition)))))))

(defmethod query-watermark-offsets
    ((consumer consumer)
     (topic string)
     (partition integer)
     &key (timeout-ms 5000))
  (cffi:with-foreign-objects ((low :int64) (high :int64))
    (with-slots (rd-kafka-consumer) consumer
      (let ((err (cl-rdkafka/ll:rd-kafka-query-watermark-offsets
                  rd-kafka-consumer
                  topic
                  partition
                  low
                  high
                  timeout-ms)))
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'topic+partition-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)
                 :topic topic
                 :partition partition))
        (list (cffi:mem-ref low :int64)
              (cffi:mem-ref high :int64))))))

(defmethod offsets-for-times
    ((consumer consumer)
     (timestamps list)
     &key (timeout-ms 5000))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list
        toppar-list
        (alloc-toppar-list timestamps :topic #'caar :partition #'cdar :offset #'cdr)
      (let ((err (cl-rdkafka/ll:rd-kafka-offsets-for-times
                  rd-kafka-consumer
                  toppar-list
                  timeout-ms))
            alist-to-return)
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))
        (foreach-toppar toppar-list (topic partition offset err)
          (let (skip-p)
            (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
              (cerror (format nil "Don't include `~A:~A` in the returned alist."
                              topic
                              partition)
                      'topic+partition-error
                      :description (cl-rdkafka/ll:rd-kafka-err2str err)
                      :topic topic
                      :partition partition)
              (setf skip-p t))
            (unless skip-p
              (push `((,topic . ,partition) . ,offset) alist-to-return))))
        alist-to-return))))

(defmethod positions ((consumer consumer) (topic+partitions list))
  (with-slots (rd-kafka-consumer) consumer
    (with-toppar-list
        toppar-list
        (alloc-toppar-list topic+partitions :topic #'car :partition #'cdr)
      (let ((err (cl-rdkafka/ll:rd-kafka-position
                  rd-kafka-consumer
                  toppar-list))
            alist-to-return)
        (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
          (error 'kafka-error
                 :description (cl-rdkafka/ll:rd-kafka-err2str err)))
        (foreach-toppar toppar-list (topic partition offset err)
          (let (skip-p)
            (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
              (cerror (format nil "Don't include `~A:~A` in the returned alist."
                              topic
                              partition)
                      'topic+partition-error
                      :description (cl-rdkafka/ll:rd-kafka-err2str err)
                      :topic topic
                      :partition partition)
              (setf skip-p t))
            (unless skip-p
              (push
               (cons `(,topic . ,partition)
                     (unless (= offset cl-rdkafka/ll:rd-kafka-offset-invalid)
                       offset))
               alist-to-return))))
        alist-to-return))))

(defmethod close ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((err (cl-rdkafka/ll:rd-kafka-consumer-close rd-kafka-consumer)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
        (error 'kafka-error :description (cl-rdkafka/ll:rd-kafka-err2str err))))))
