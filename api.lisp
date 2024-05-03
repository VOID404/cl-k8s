(in-package :cl-kubernetes)

(defgeneric load-config (source)
  (:documentation
   "Load a YAML configuration from a file or a list of files."))

(defvar *tmp-files* nil)

(defun inline->file (value file-type)
  (if (null value)
      value
      (with-temporary-file (:stream os :pathname path :type file-type :keep t)
        (setf path (truenamize path))
        (write-sequence (qbase64:decode-string value) os)
        (push path *tmp-files*)
        path)))

;; https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/#merging-kubeconfig-files
(defun merge-configurations (&optional current new)
  "Destructively merge two k8s configurations.

Adds in CURRENT all the entries (K,V) from NEW for which K is not
currently associated to a value in CURRENT.

When called with zero arguments, produce an empty HASH-TABLE (this is
to satisfy REDUCE and easily build empty configurations)."
  (cond
    ((and current new)
     (maphash (lambda (key new-value)
                (multiple-value-bind (current-value exists-p)
                    (gethash key current)
                  (declare (ignore current-value))
                  (unless exists-p
                    (setf (gethash key current) new-value))))
              new)
     current)
    (t (make-hash-table :test #'equal))))

(defmethod load-config ((sequence sequence))
  "Load and merge a sequence of configuration files."
  ;; merge according to priority rules.
  (reduce #'merge-configurations
          ;; may error when deserializing
          (mapcar #'load-config
                  ;; ignore non-existing files
                  (delete nil (map 'list #'probe-file sequence)))))

(defmethod load-config ((path pathname))
  "Load a single configuration file."
  (let ((file (cl-yy:yaml-load-file path :size-limit (* 1024 1024))))
    (when (users file)
      (loop
        for named-auth in (users file)
        for auth = (user named-auth)

        for cert-data = (gethash "client-certificate-data" auth)
        for key-data = (gethash "client-key-data" auth)

        when cert-data
          do (setf (client-certificate auth)
                   (inline->file cert-data "crt"))

        when key-data
          do (setf (client-key auth)
                   (inline->file key-data "key"))))

    (when (clusters file)
      (loop
        for named-cluster in (clusters file)
        for cluster = (cluster named-cluster)

        for cert-data = (gethash "certificate-authority-data" cluster)
        when cert-data
          do (setf (certificate-authority cluster)
                   (inline->file cert-data "ca"))))
    file))

(defmethod load-config :around ((path pathname))
  "Add an IGNORE restart around LOAD-CONFIG for pathnames."
  (restart-case (call-next-method)
    (ignore ()
      :report "Ignore this configuration file."
      ;; return empty configuration
      (merge-configurations))))

(defun default-config ()
  "Load the default configuration in this environment.

First, try to load configuration from one or more files listed in the
KUBECONFIG environment variable, if that variable is set.

Otherwise, try to read the configuration file from the home user
directory (~/.kube/config).

If this file does not exist, return a default configuration."
  (let ((source (or (getenv-pathnames "KUBECONFIG")
                    (probe-file (merge-pathnames #P".kube/config"
                                                 (user-homedir-pathname))))))
    (if source
        (load-config source)
        (alist-hash-table
         '(("apiVersion" "v1")
           ("kind" "Config"))
         :test #'equal))))

(defmacro define-accessors (name &optional (key (string-downcase name)))
  "Define both NAME and (SETF NAME) to access slot KEY in objects.

KEY is a string that defaults to the NAME symbol (downcased), and
represents the name of the key to access in an object to retrieve its
value."
  (check-type name symbol)
  (check-type key string)
  (let ((object (copy-symbol :object))
        (value (copy-symbol :value)))
    `(progn
       ;; Inline accessors: they are not going to change at runtime.
       (declaim (inline ,name (setf ,name)))

       ;; Reader: allow NIL object.
       (defun ,name (,object)
         ,(format
           nil
           "Get the value associated with ~S in OBJECT, or NIL. ~%~%~

            If OBJECT is NIL, returns NIL."
           key)
         (and ,object (gethash ,key ,object)))

       ;; Writer
       (defun (setf ,name) (,value ,object)
         ,(format
           nil
           "Set the value associated with ~S in OBJECT to VALUE."
           key)
         (setf (gethash ,key ,object) ,value)))))

;; sorted alphabetically

(define-accessors certificate-authority)
(define-accessors client-certificate)
(define-accessors client-key)
(define-accessors cluster)
(define-accessors clusters)
(define-accessors context)
(define-accessors contexts)
(define-accessors current-context)
(define-accessors name)
(define-accessors server)
(define-accessors user)
(define-accessors users)

;;;; UTILITY FUNCTIONS

(declaim (inline find-by-name))

(defun find-by-name (name sequence)
  (find name sequence :test #'equal :key #'name))

;; Resolve references to objects by name

(defun get-context (config context-name)
  (find-by-name context-name (contexts config)))

(defun get-user (config user-name)
  (find-by-name user-name (users config)))

(defun get-cluster (config cluster-name)
  (find-by-name cluster-name (clusters config)))

;; Get some current object by name.
;; Since data typically looks like this:
;;
;; - context:
;;     cluster: development
;;     namespace: frontend
;;     user: developer
;;   name: dev-frontend
;;
;; ... the object we find when searching for "dev-frontend" is the
;; exterior one, which holds the "name" key and a "context" key. But
;; the object we want to get is the one under "context". That's why
;; the functions below descend into the object being found by name.

(defun get-current-context (config)
  (context
   (get-context config (current-context config))))

(defun get-current-user (config)
  (if-let ((context (get-current-context config)))
    (user
     (get-user config (user context)))))

(defun current-cluster (config)
  (if-let ((context (get-current-context config)))
    (cluster
     (get-cluster config (cluster context)))))


;;;; API CALLS


(defun call-api (path
                 &key
                   (method :GET)
                   (host "http://localhost:8080")
                   (body nil)
                   (content-type "application/json")
                   (user-agent "cl-k8s 0.0.1")
                   (insecure-tls-no-verify nil)
                   (ca-file nil)
                   (client-certificate nil)
                   (client-key nil))
  (let ((uri (concatenate 'string host path)))
    (print body)
    (multiple-value-bind (stream code)
        (drakma:http-request
         uri
         :want-stream t
         :method method
         :content (if body (json:encode-json-to-string body) nil)
         :content-type content-type
         :verify (if insecure-tls-no-verify nil :required)
         :ca-file ca-file
         :certificate client-certificate
         :key client-key
         :user-agent user-agent)
      (values (json:decode-json stream) code))))

(defun call-api-with-config (path
                             config 
                             &key
                               (method :GET)
                               (body nil)
                               (content-type "application/json")
                               (user-agent "cl-k8s 0.0.1")
                               (insecure-tls-no-verify nil))
  (let ((cluster (current-cluster config))
        (user (get-current-user config)))
    (call-api
     path
     :method method
     :body body
     :content-type content-type
     :user-agent user-agent
     :host (server cluster)
     :ca-file (certificate-authority cluster)
     :insecure-tls-no-verify insecure-tls-no-verify ; (get-insecure-tls-no-verify config)
     :client-certificate (client-certificate user)
     :client-key (client-key user))))

