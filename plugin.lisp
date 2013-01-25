;; wookie-plugin-export provides a shared namespace for plugins to provide
;; their public symbols to. apps can :use this package to gain access to
;; the shared plugin namespace.
(defpackage :wookie-plugin-export
  (:use :cl))

(defpackage :wookie-plugin
  (:use :cl :wookie)
  (:export #:register-plugin
           #:set-plugin-request-data
           #:get-plugin-request-data
           #:*plugin-folders*
           #:*enabled-plugins*
           #:load-plugins
           #:defplugfun)
  (:import-from :wookie))
(in-package :wookie-plugin)

(defvar *plugins* (make-hash-table :test #'eq)
  "A hash table holding all registered Wookie plugins.")
(defvar *plugin-config* nil
  "A hash table holding configuration values for all plugins.")
(defvar *plugin-folders* (list "./wookie-plugins/"
                               (asdf:system-relative-pathname :wookie #P"wookie-plugins/"))
  "A list of directories where Wookie plugins can be found.")
(defvar *enabled-plugins* '(:get :post :multipart :cookie)
  "A list of (keyword) names of enabled plugins.")
(defvar *available-plugins* nil
  "A list (generated by load-plugins) that holds the names of all plugins
   available for loading. Used to help the dependency system resolve.")

(defun register-plugin (plugin-name meta init-function unload-function)
  "Register a plugin in the Wookie plugin system. Generally this is called from
   a plugin.lisp file, but can also be called elsewhere in the plugin. The
   plugin-name argument must be a unique keyword, meta is a plist of information
   about the plugin (name, author, description, etc), and init-fn is the
   initialization function called that loads the plugin (called only once, on
   register)."
  (let ((plugin-entry (list :name plugin-name
                            :meta meta
                            :init-function init-function
                            :unload-function unload-function)))
    ;; mark the plugin as available (even though it may not be enabled)
    (unless (find plugin-name *available-plugins*
                  :test (lambda (pn pe)
                          (eq pn (getf pe :name))))
      (push plugin-entry *available-plugins*))
    ;; if enabled, load it
    (when (and (find plugin-name *enabled-plugins*)    ; make sure it's enabled
               (not (gethash plugin-name *plugins*)))  ; make sure it's not loaded already
      (setf (gethash plugin-name *plugins*) plugin-entry)
      (funcall init-function))))

(defun unload-plugin (plugin-name)
  "Unload a plugin from the wookie system. If it's currently registered, its
   unload-function will be called.
   
   Also unloads any current plugins that depend on this plugin. Does this
   recursively so all depencies are always resolved."
  ;; unload the plugin
  (let ((plugin (gethash plugin-name *plugins*)))
    (when plugin
      (funcall (getf plugin :unload-function (lambda ())))
      (remhash plugin-name *plugins*)))
  
  ;; search far and wide for plugins depending on this one. if found, unload
  ;; those as well (and thanks to recursion, the plugins depending on THEM).
  (let ((to-unload (loop for plugin-entry being the hash-values of *plugins*
                         if (find plugin-name (getf (getf plugin-entry :meta) :depends-on))
                         collect (getf plugin-entry :name))))
    (dolist (unload-plugin to-unload)
      (unload-plugin unload-plugin))))

(defun plugin-config (plugin-name)
  "Return the configuration for a plugin. Setfable."
  (unless (hash-table-p *plugin-config*)
    (setf *plugin-config* (make-hash-table :test #'eq)))
  (gethash plugin-name *plugin-config*))

(defun (setf plugin-config) (config plugin-name)
  "Allow setting of plugin configuration via setf."
  (unless (hash-table-p *plugin-config*)
    (setf *plugin-config* (make-hash-table :test #'eq)))
  (setf (gethash plugin-name *plugin-config*) config))

(defun set-plugin-request-data (plugin-name request data)
  "When a plugin wants to store data available to the main app, it can do so by
   storing the data into the request's plugin data. This function allows this by
   taking the plugin-name (keyword), request object passed into the route, and
   the data to store."
  (unless (hash-table-p (request-plugin-data request))
    (setf (request-plugin-data request) (make-hash-table :test #'eq)))
  (setf (gethash plugin-name (request-plugin-data request)) data))

(defun get-plugin-request-data (plugin-name request)
  "Retrieve the data stored into a request object for the plugin-name (keyword)
   plugin."
  (let ((data (request-plugin-data request)))
    (when (hash-table-p data)
      (gethash plugin-name data))))

(defun resolve-dependencies ()
  "For each registered plugin, makes sure all dependencies are met. If a plugin
   has dependencies that are not currently loaded, the *available-plugins* list
   is checked for a match. If found, the dependency is loaded, if not the
   depending plugin is unregistered."
  (let ((num-resolved-dependencies 0))
    (loop for plugin-entry being the hash-values of *plugins* do
      (let ((dependencies (getf (getf plugin-entry :meta) :depends-on)))
        (when dependencies
          (dolist (dep dependencies)
            ;; TODO: try optima for this shit
            (let ((available-dep (find dep *available-plugins*
                                       :test (lambda (a b)
                                               (eq a (getf b :name))))))
              (cond ((gethash dep *plugins*)
                     ;; dep is loaded already...do nothing!
                     )
                    (available-dep
                     ;; we got an available dependency...load it
                     (incf num-resolved-dependencies)
                     (funcall (getf available-dep :init-function))
                     (setf (gethash (getf available-dep :name) *plugins*) available-dep))
                    (t
                     ;; no deal. unload the current plugin (and break the loop)
                     ;; unload-plugin will also unload plugins depending on this
                     ;; one.
                     (unload-plugin (getf plugin-entry :name))
                     (return))))))))
    ;; if we did resolve deps, there are possibly more dependencies to load.
    ;; keep going until we've either loaded or unloaded all necessary plugins
    (when (< 0 num-resolved-dependencies)
      (resolve-dependencies))))
  
(defun load-plugins (&key compile)
  "Load all plugins under the *plugin-folder* fold (set with set-plugin-folder).
   There is also the option to compile the plugins (default nil)."
  (unless *plugins*
    (setf *plugins* (make-hash-table :test #'eq)))
  ;; unload current plugins
  (loop for name being the hash-keys of *plugins* do
    (unload-plugin name))
  (setf *available-plugins* nil)
  (dolist (plugin-folder *plugin-folders*)
    (dolist (dir (cl-fad:list-directory plugin-folder))
      (let ((dirstr (namestring dir)))
        ;; NOTE: not doing enabled check here since we want to know all
        ;; available plugins
        (when (cl-fad:directory-exists-p dir)
          (let ((plugin-file (concatenate 'string dirstr
                                          "plugin.lisp")))
            (when (cl-fad:file-exists-p plugin-file)
              (when compile
                (setf plugin-file (compile-file plugin-file)))
              (load plugin-file)))))))
  (resolve-dependencies))

(defmacro defplugfun (name args &body body)
  "Define a plugin function that is auto-exported to the :wookie-plugin-export
   package."
  `(progn
     (defun ,name ,args ,@body)
     (shadowing-import ',name :wookie-plugin-export)
     (export ',name :wookie-plugin-export)))


