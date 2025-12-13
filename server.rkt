#lang racket

(require racket/date racket/tcp)

(define LOG_PATH (build-path "server.debug"))
(define LOG_PORT (open-output-file LOG_PATH #:exists 'append))

(define (time/string) (date->string (current-date) #t))

(define (handle/cmd-data data src-ip)
  (fprintf LOG_PORT "((type command) (time ~s) (src-ip ~s) (cmd ~s))~n" (time/string) src-ip data) (flush-output LOG_PORT)
  
)

(define (handle/unknown u src-ip)
  (fprintf LOG_PORT "((type unknown) (time ~s) (sub-type ~s) (version ~s))~n" (time/string) (dict-ref u 'type) (dict-ref u 'version))
)

(define (handle/init output src-ip shell-type)
  (fprintf LOG_PORT "((type init) (time ~s) (src-ip ~s) (shell ~s))~n" (time/string) src-ip shell-type)
  (flush-output LOG_PORT)
  ;; 根据 shell 类型选择不同的初始化脚本
  (define welcome-file
    (match shell-type
      ["fish" "welcome.fish"]
      ["sh" "welcome.sh"]
      [_ 
        (fprintf LOG_PORT "((warn ) (type init) (time ~s) (shell ~s) (reason ~s))~n" (time/string) src-ip shell-type "unknown shell type.")
        (flush-output LOG_PORT)
        "welcome.sh"]))  ; 默认使用 sh
  (cond
    [(file-exists? welcome-file)
      (call-with-input-file welcome-file (lambda (input)
        (copy-port input output)))]
    [else
      (fprintf LOG_PORT "((error ) (time ~s) (msg ~s) (file ~s))~n" (time/string) "welcome file not found:" welcome-file)
      (flush-output LOG_PORT)]
  )
)

(define (handle/tcp-connect input output)
  (match-define-values (src-ip _) (tcp-addresses input))
  (fprintf LOG_PORT "((type meta-connect) (time ~s) (src-ip ~s))~n" (time/string) src-ip) (flush-output LOG_PORT)
  (define r (read input))
  (define r^ (for/hash ([(k v) (in-dict r)]) (values k v)))
  (match r^
    ;; 版本 1.0.1: 初始化消息（包含 shell 类型）
    [(hash 'version '(1 0 1) 'type 'init 'shell shell-type) (handle/init output src-ip shell-type)]
    ;; 版本 1.0.0: 命令消息
    [(hash 'version '(1 0 0) 'type 'command 'data data) (handle/cmd-data data src-ip)]
    [(hash 'version '(1 0 0) 'type 'command 'data data 'duration duration) (handle/cmd-data data src-ip)]
    ;; 版本 1.0.0: 初始化消息（兼容旧客户端）
    [(hash 'version '(1 0 0) 'type 'init) (handle/init output src-ip "sh")]
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
      (match-define-values (input output) (tcp-listen listener))
      (thread (thunk (with-handlers ([exn:fail? (lambda (e) (custodian-shutdown-all cus2) (raise e))])
        (handle/tcp-connect input output)
        )
        (custodian-shutdown-all cus2)))
    )
  )))))
  (tcp-server-thread t)
  (tcp-custodian cus)
  t 
)

(define (server-close)
  (kill-thread (tcp-server-thread))
  (custodian-shutdown-all (tcp-custodian))
)
