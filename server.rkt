#lang racket

(require racket/date racket/tcp)

(define LOG_PATH (build-path "server.debug"))
(define LOG_PORT (open-output-file LOG_PATH #:exists 'append))

(define (time/string) (date->string (current-date) #t))

(define (lprintf . args)
  (define args^ (cons LOG_PORT args))
  (apply fprintf args^)
  (flush-output LOG_PORT))

(define (handle/cmd-data data src-ip)
  (lprintf "((type command) (time ~s) (src-ip ~s) (cmd ~s))~n" (time/string) src-ip data)
)

(define (handle/unknown u src-ip)
  (lprintf "((type unknown) (time ~s) (sub-type ~s) (version ~s))~n" (time/string) (dict-ref u 'type) (dict-ref u 'version))
)

(define rx-filters '(
  #px"^vi"
  #px"^tmux"
  #px"^less"
  #px"^more"
  #px"^top"
  #px"^htop"
  #px"^sh"
  #px"^bash"
  #px"^fish"
))

(define (handle/notification data src-ip)
  (define l (for/or ([r rx-filters]) (regexp-match r data)))
  (cond
    [(not l) (do-notification/win src-ip data "remainder")]
    [else (lprintf "((info ) (time ~s) (cmd ~s) (action \"ignore\"))~n" (time/string) data)])
)

(define (handle/init output src-ip shell-type)
  (lprintf "((type init) (time ~s) (src-ip ~s) (shell ~s))~n" (time/string) src-ip shell-type)
  ;; 根据 shell 类型选择不同的初始化脚本
  (define welcome-file
    (match shell-type
      ["fish" "welcome.fish"]
      ["sh" "welcome.sh"]
      [_
        (lprintf "((warn ) (type init) (time ~s) (shell ~s) (reason ~s))~n" (time/string) src-ip shell-type "unknown shell type.")
        "welcome.sh"]))  ; 默认使用 sh
  (cond
    [(file-exists? welcome-file)
      (call-with-input-file welcome-file (lambda (input)
        (copy-port input output)))]
    [else
      (lprintf "((error ) (time ~s) (msg ~s) (file ~s))~n" (time/string) "welcome file not found:" welcome-file)
    ]
  )
)

(define (handle/tcp-connect input output)
  (match-define-values (_ src-ip) (tcp-addresses input))
  (lprintf "((type meta-connect) (time ~s) (src-ip ~s))~n" (time/string) src-ip)
  (define r (read input))
  (define r^ (for/hash ([(k v) (in-dict r)]) (values k v)))
  (match r^
    ;; 版本 1.0.1: 初始化消息（包含 shell 类型）
    [(hash 'version '(1 0 1) 'type 'init 'shell shell-type) (handle/init output src-ip shell-type) (close-output-port output) ]
    ;; 版本 1.0.0: 命令消息
    [(hash 'version '(1 0 0) 'type 'command 'data data) (close-output-port output) (handle/cmd-data data src-ip) (handle/notification data src-ip)]
    [(hash 'version '(1 0 0) 'type 'command 'data data 'duration duration) (close-output-port output) (handle/cmd-data data src-ip) (when (>= duration 3000) (handle/notification data src-ip)) ]
    ;; 版本 1.0.0: 初始化消息（兼容旧客户端）
    [(hash 'version '(1 0 0) 'type 'init) (close-output-port output) (handle/init output src-ip "sh")]
    ;; 未知版本或类型
    [(hash 'version _ 'type _ #:open) (handle/unknown r^ src-ip)]
  )
)

(define tcp-server-thread (make-parameter #f))
(define tcp-custodian (make-parameter #f))

(define MAX_ALLOW_WAIT 128)

(define (server-listen port-no)
  (define cus (make-custodian))
  (define t (thread (thunk (parameterize ([current-custodian cus]) (define listener (tcp-listen port-no MAX_ALLOW_WAIT)) (let loop ()
    (define cus2 (make-custodian))
    (parameterize ([current-custodian cus2])
      (match-define-values (input output) (tcp-accept listener))
      (thread (thunk (with-handlers ([exn:fail? (lambda (e) (custodian-shutdown-all cus2) (raise e))])
        (handle/tcp-connect input output)
        )
        (custodian-shutdown-all cus2)))
    )
    (loop)
  )))))
  (tcp-server-thread t)
  (tcp-custodian cus)
  t
)

(define (server-close)
  (kill-thread (tcp-server-thread))
  (custodian-shutdown-all (tcp-custodian))
)

(define (do-notification/win title content sound)
  (define tmp-path (make-temporary-file "notif-~a.ps1"))
  (with-output-to-file tmp-path (thunk (printf "New-BurntToastNotification -Text ~s, ~s -Sound ~s~n" title content sound)) #:exists 'truncate/replace)
  (system (format "powershell -ExecutionPolicy Unrestricted -F ~a" tmp-path))
  (with-handlers ([exn:fail:filesystem? (lambda (e) (lprintf "((warn ) (time ~s) (reason ~s) (file ~s) (sub-type do-notification/win))~n" (time/string) "fail to delete .ps1 script" tmp-path))]) (delete-file tmp-path))
)

(define (install-notification/win)
  (define tmp-path (make-temporary-file "notif-~a.ps1"))
  (with-output-to-file tmp-path (thunk (printf "Install-Module -Name BurntToast~n")) #:exists 'truncate/replace)
  (system (format "powershell -ExecutionPolicy Unrestricted -F ~a" tmp-path))
  (with-handlers ([exn:fail:filesystem? (lambda (e) (lprintf "((warn ) (time ~s) (reason ~s) (file ~s) (sub-type install-notification/win))~n" (time/string) "fail to delete .ps1 script" tmp-path))]) (delete-file tmp-path))
)
