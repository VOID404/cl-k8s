(in-package :cl-user)

(defpackage :cl-kubernetes
  (:nicknames #:k8s)
  (:use :cl)
  (:import-from :alexandria
                #:alist-hash-table
                #:ensure-list
                #:if-let)
  (:import-from :uiop
                #:inter-directory-separator
                #:getenv-pathnames
                #:truenamize
                #:with-temporary-file)
  (:import-from :uiop/common-lisp
                #:user-homedir-pathname)
  (:export #:call-api
           #:call-api-with-config
           #:load-config
           #:default-config
           #:*tmp-files*))

(defpackage #:cl-kubernetes-examples
  (:use :cl :k8s))
