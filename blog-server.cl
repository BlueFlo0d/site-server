(load "~/quicklisp/setup.lisp")
(ql:quickload "aserve")
(ql:quickload "cl-ppcre")
(defpackage :blog-server (:use :cl :net.aserve :net.html.generator))
(in-package :blog-server)
(start :port 80)
(defvar *comment-table* (make-hash-table :test 'equal))
(defvar *next-comment-id-table* (make-hash-table :test 'equal))

(defvar *document-root* "/Users/hongqiantan/blog/")
(defun touch-comment-table (filename)
  (multiple-value-bind (comment-table table-exist)
      (gethash filename *comment-table*)
    (unless table-exist
      (let ((comment-file-name
              (concatenate 'string filename ".comments")))
        (setf (gethash filename *comment-table*) (make-hash-table))
        (setf (gethash filename *next-comment-id-table*) 1)
        (setf comment-table (gethash filename *comment-table*))
        (setf (gethash 0 comment-table) '())
        (if (probe-file comment-file-name)
            (with-open-file (comment-file-stream comment-file-name)
              (loop for line = (read-line comment-file-stream nil)
                    while line
                    do (multiple-value-bind
                             (num-parent parent-field-end)
                           (parse-integer line :junk-allowed t)
                         (multiple-value-bind
                               (num-id id-field-end)
                             (parse-integer line :junk-allowed t
                                                 :start (1+ parent-field-end))
                           (setf (gethash filename *next-comment-id-table*)
                                 (max (gethash filename *next-comment-id-table*) (1+ num-id)))
                           (comment-table-insert
                            comment-table
                            num-id
                            num-parent
                            (subseq line (1+ id-field-end)))))))))
      )))
(defun comment-table-insert (comment-table
                             num-id
                             num-parent
                             content)
  (multiple-value-bind (child-list exist)
      (gethash num-parent comment-table)
    (if exist
        (progn
          (push (cons num-id content) (gethash num-parent comment-table))
         (setf (gethash num-id comment-table) '()))
        (format t "ERROR: parent ~D does not exist.~%" num-parent))))
(defun post-new-comment (req filename nickname contact parent text uri)
  (touch-comment-table filename)
  (let* ((num-parent
           (if (string-equal "" parent)
               0
               (let ((result (parse-integer parent)))
                 (if result
                     result
                     (failed-request req)))))
         (empty-uri (string-equal uri ""))
         (empty-name (string-equal nickname ""))
         (empty-text (string-equal text ""))
         (empty-contact (string-equal contact ""))
         (content-string
           (let ((content-stream
                   (make-string-output-stream)))
             (html-stream content-stream
                          (:p (:b (:princ-safe
                                   (format nil "#~D"
                                           (gethash filename *next-comment-id-table*))))
                              (:princ-safe
                                  (format nil " by ~a<"
                                           nickname))
                              (if empty-contact
                                  (html "CIA top secret")
                                  (html ((:a href (concatenate 'string
                                                               "mailto:"
                                                               contact)) (:princ-safe contact))))
                              (:princ-safe ">"))
                          (:p
                           (unless empty-uri
                             (html ((:a href uri) (:princ-safe uri))))
                           (unless (or empty-uri empty-text)
                             (html :br))
                           (unless empty-text
                             (html (:princ-safe
                                    (cl-ppcre:regex-replace-all
                                     (format nil "~%")
                                     text
                                     "<br/>"))))))
             (get-output-stream-string content-stream))))
    (if (or empty-name (and empty-text empty-uri))
        (failed-request req)
        (progn
          (comment-table-insert
           (gethash filename *comment-table*)
           (gethash filename *next-comment-id-table*)
           num-parent
           content-string)
          (with-open-file (comment-file-stream
                           (concatenate 'string filename ".comments")
                           :direction :output :if-exists :append :if-does-not-exist :create)
            (format comment-file-stream "~D ~D " num-parent (gethash filename *next-comment-id-table*))
            (write-line content-string comment-file-stream))
          (setf (gethash filename *next-comment-id-table*)
                (1+ (gethash filename *next-comment-id-table*)))))))
(defun format-comment-list (comment-table content child-list)
  (html ((:div class "comment") (:princ content)
              (mapc (lambda (child)
                     (format-comment-list comment-table
                                          (cdr child)
                                          (gethash (car child) comment-table)))
                    child-list))))
(defun format-comments (filename)
  (touch-comment-table filename)
  (let* ((comment-table
           (gethash filename *comment-table*))
         (root-list (gethash 0 comment-table)))
    (if (null root-list)
        (html "No comments yet.")
        (mapc (lambda (child)
                     (format-comment-list comment-table
                                          (cdr child)
                                          (gethash (car child) comment-table)))
                    root-list))))
(defun response-with-comments (req ent filename info)
  (with-open-file
      (src-stream filename)
    (loop for line = (read-line src-stream nil)
          while line
          do (if (string-equal line
                               (format nil "<!--%comments%-->"))
                 (format-comments filename)
                 (html (:princ line) :newline)))
    t))
(setf (gethash "svg" *mime-types*) "images/xml+svg")
(publish-directory :prefix "/" :destination *document-root*
                   :filter
                   (lambda (req ent filename info)
                     (if (string-equal "text/html" (gethash
                                                    (pathname-type (pathname filename))
                                                    *mime-types*))
                         (case (request-method req)
                           (:post (let ((nickname (request-query-value "nickname" req))
                                        (contact (request-query-value "contact" req))
                                        (parent (request-query-value "rep" req))
                                        (text (request-query-value "text" req))
                                        (uri (request-query-value "url" req)))
                                    (if (and nickname contact
                                             parent text uri)
                                        (post-new-comment
                                         req
                                         filename
                                         nickname
                                         contact
                                         parent
                                         text
                                         uri)
                                        (failed-request req)))
                            (with-http-response (req ent :response *response-found*)
                              (setf (reply-header-slot-value req :location)
                                                         (request-uri req))
                             (with-http-body (req ent)))
                            t)
                           (:get
                            (with-http-response (req ent)
                              (with-http-body (req ent)
                                  (response-with-comments req ent filename info)))
                            t)
                           (otherwise (failed-request req)))
                         nil)))
(publish-directory :prefix "/ltximg/" :destination (concatenate 'string
                                                                *document-root* "posts/ltximg/"))
