#lang racket/base

;; ----------------------------------------------------------------------------
;; customization

(define toplevel-prefix     (make-parameter "-")) ; when not in a module
(define saved-values-number (make-parameter 5))
(define saved-values-char   (make-parameter #\^))
(define wrap-column         (make-parameter 79))
;; TODO: when there's a few more of these, make them come from the prefs

;; ----------------------------------------------------------------------------

(require racket/list racket/match)

;; ----------------------------------------------------------------------------
;; utilities

;; autoloads: avoid loading a ton of stuff to minimize startup penalty
(define autoloaded-specs (make-hasheq))
(define (autoloaded? sym) (hash-ref autoloaded-specs sym #f))
(define-syntax-rule (defautoload libspec id ...)
  (begin (define (id . args)
           (set! id (dynamic-require 'libspec 'id))
           (hash-set! autoloaded-specs 'libspec #t)
           (hash-set! autoloaded-specs 'id #t)
           (apply id args))
         ...))

(defautoload racket/system          system system*)
(defautoload racket/file            file->string)
(defautoload setup/path-to-relative path->relative-string/setup)
(defautoload syntax/modcode         get-module-code)
(defautoload racket/path            find-relative-path)

;; similar, but just for identifiers
(define-namespace-anchor anchor)
(define (here-namespace) (namespace-anchor->namespace anchor))
(define (make-lazy-identifier sym from)
  (define id #f)
  (λ () (or id (parameterize ([current-namespace (here-namespace)])
                 (eval (namespace-syntax-introduce
                        (datum->syntax #f #`(require #,from))))
                 (set! id (namespace-symbol->identifier sym))
                 id))))

;; makes it easy to use meta-tools without user-namespace contamination
(define (eval-sexpr-for-user form)
  (eval (namespace-syntax-introduce (datum->syntax #f form))))

(define (modspec->path modspec) ; returns a symbol for 'foo specs
  (resolved-module-path-name ((current-module-name-resolver) modspec #f #f)))
(define (mpi->name mpi)
  (resolved-module-path-name (module-path-index-resolve mpi)))
(define (->relname x)
  (if (path-string? x) (path->relative-string/setup x) x))

(define (here-source) ; returns a path, a symbol, or #f (= not in a module)
  (let* ([x (datum->syntax #'here '(#%variable-reference))]
         [x (eval (namespace-syntax-introduce x))]
         [x (variable-reference->module-source x)])
    x))

(define (phase->name phase [fmt #f])
  (define s
    (case phase
      [(0) #f] [(#f) "for-label"] [(1) "for-syntax"] [(-1) "for-template"]
      [else (format "for-meta:~a" phase)]))
  (cond [(not fmt) s] [s (format fmt s)] [else ""]))

;; true if (quote sym) is a known module name
(define (module-name? sym)
  (and (symbol? sym)
       (with-handlers ([exn? (λ (_) #f)]) (module->imports `',sym) #t)))

(define last-output-port #f)
(define (maybe-new-output-port)
  (unless (eq? last-output-port (current-output-port))
    (when last-output-port (flush-output last-output-port)) ; just in case
    (set! last-output-port (current-output-port))
    (flush-output last-output-port)
    (port-count-lines! last-output-port)))
(define (fresh-line)
  (maybe-new-output-port)
  (flush-output last-output-port)
  (define-values [line col pos] (port-next-location last-output-port))
  (unless (eq? col 0) (newline)))
(define (prompt-shown)
  ;; right after an input expression is entered the terminal won't show the
  ;; newline, so as far as column counting goes it's still after the prompt
  ;; which leads to bad output in practice.  (at least in the common case where
  ;; IO share the same terminal.)
  (maybe-new-output-port)
  (define-values [line col pos] (port-next-location last-output-port))
  (set-port-next-location! last-output-port line 0 pos))

;; wrapped `printf' (cheap but effective), aware of the visual col
(define wrap-prefix (make-parameter ""))
(define (wprintf fmt . args)
  (let ([o    (current-output-port)]
        [wcol (wrap-column)]
        [pfx  (wrap-prefix)]
        [strs (regexp-split #rx" +" (apply format fmt args))])
    (write-string (car strs) o)
    (for ([str (in-list (cdr strs))])
      (define-values [line col pos] (port-next-location o))
      (if ((+ col (string-length str)) . >= . wcol)
        (begin (newline o) (write-string pfx o))
        (write-string " " o))
      (write-string str o))))

;; ----------------------------------------------------------------------------
;; toplevel "," commands management

(struct command (names argline blurb desc handler))
(define commands (make-hasheq))
(define commands-list '()) ; for help displays, in definition order
(define current-command (make-parameter #f))
(define (register-command! names blurb argline desc handler)
  (let* ([names (if (list? names) names (list names))]
         [cmd (command names blurb argline desc handler)])
    (for ([n (in-list names)])
      (if (hash-ref commands n #f)
        (error 'defcommand "duplicate command name: ~s" n)
        (hash-set! commands n cmd)))
    (set! commands-list (cons cmd commands-list))))
(define-syntax-rule (defcommand cmd+aliases argline blurb [desc ...]
                      body0 body ...)
  (register-command! `cmd+aliases `argline `blurb `(desc ...)
                     (λ () body0 body ...)))

(define (cmderror fmt #:default-who [dwho #f] . args)
  (let ([cmd (current-command)])
    (raise-user-error (or (and cmd (string->symbol (format ",~a" cmd)))
                          dwho '???)
                      (apply format fmt args))))

;; returns first peeked non-space/tab char (#\return is considered space too)
(define string->list*
  (let ([t (make-weak-hasheq)]) ; good for string literals
    (λ (s) (hash-ref! t s (λ () (string->list s))))))
(define (skip-spaces/peek [skip " \t\r"])
  (let ([skip (string->list* skip)])
    (let loop ()
      (let ([ch (peek-char)])
        (if (memq ch skip) (begin (read-char) (loop)) ch)))))

(define (getarg kind [flag 'req])
  (define (argerror fmt . args)
    (apply cmderror #:default-who 'getarg fmt args))
  (define (missing) (argerror "missing ~a argument" kind))
  (define (get read)
    (let loop ([flag flag])
      (case flag
        [(req)   (let ([x (if (eq? #\newline (skip-spaces/peek)) eof (read))])
                   (if (eof-object? x) (missing) x))]
        [(opt)   (and (not (eq? #\newline (skip-spaces/peek))) (loop 'req))]
        [(list)  (let ([x (loop 'opt)])
                   (if x (cons x (loop 'list)) '()))]
        [(list+) (cons (loop 'req) (loop 'list))]
        [else (error 'getarg "unknown flag: ~e" flag)])))
  (define (read-string-arg)
    (define ch (skip-spaces/peek " \t\r\n"))
    (let* ([i (current-input-port)]
           [m (if (eq? ch #\")
                (let ([m (regexp-match #px#"((?:\\\\.|[^\"\\\\]+)+)\"" i)])
                  (and m (regexp-replace* #rx#"\\\\(.)" (cadr m) #"\\1")))
                (cond [(regexp-match #px#"\\S+" i) => car] [else #f]))])
      (if m (bytes->string/locale m) eof)))
  (define (read-line-arg)
    (regexp-replace* #px"^\\s+|\\s+$" (read-line) ""))
  (define (process-modspec spec)
    ;; convenience: symbolic modspecs that name a file turn to a `file' spec,
    ;; and those that name a known module turn to a (quote sym) spec
    (define dtm (if (syntax? spec) (syntax->datum spec) spec))
    (if (not (symbol? dtm))
      spec
      (let* (;; try a file
             [f (expand-user-path (symbol->string dtm))]
             [f (and (file-exists? f) (path->string f))]
             [f (and f (if (absolute-path? f) `(file ,f) f))]
             ;; try a quoted one if the above failed
             [m (or f (and (module-name? dtm) `',dtm))]
             [m (and m (if (syntax? spec) (datum->syntax spec m spec) m))])
        (or m spec))))
  (define (translate arg convert)
    (and arg (if (memq flag '(list list+)) (map convert arg) (convert arg))))
  (let loop ([kind kind])
    (case kind
      [(line)    (get read-line-arg)]
      [(string)  (get read-string-arg)]
      [(path)    (translate (loop 'string) expand-user-path)]
      [(path*)   (if (eq? flag 'list)
                   (let ([args (getarg 'path 'list)])
                     (if (pair? args)
                       args
                       (let ([x (here-source)]) (if (path? x) (list x) '()))))
                   (error 'getarg "'path* must always be used with 'list"))]
      [(sexpr)   (get read)]
      [(syntax)  (translate (get read-syntax) namespace-syntax-introduce)]
      [(modspec) (translate (loop 'syntax) process-modspec)]
      [else (error 'getarg "unknown arg kind: ~e" kind)])))

(define (run-command cmd)
  (parameterize ([current-command cmd])
    (with-handlers ([void (λ (e)
                            (if (exn? e)
                              (eprintf "~a\n" (exn-message e))
                              (eprintf "~s\n" e)))])
      ((command-handler (or (hash-ref commands cmd #f)
                            (error "Unknown command:" cmd)))))))

(defcommand (help h ?) "[<command-name>]"
  "display available commands"
  ["Lists known commands and their help; use with a command name to get"
   "additional information for that command."]
  (define arg (match (getarg 'sexpr 'opt) [(list 'unquote x) x] [x x]))
  (define cmd
    (and arg (hash-ref commands arg
                       (λ () (printf "*** Unknown command: `~s'\n" arg) #f))))
  (define (show-cmd cmd indent)
    (define names (command-names cmd))
    (printf "~a~s" indent (car names))
    (when (pair? (cdr names)) (printf " ~s" (cdr names)))
    (printf ": ~a\n" (command-blurb cmd)))
  (if cmd
    (begin (show-cmd cmd "; ")
           (printf ";   usage: ,~a" arg)
           (let ([a (command-argline cmd)]) (when a (printf " ~a" a)))
           (printf "\n")
           (for ([d (in-list (command-desc cmd))])
             (printf "; ~a\n" d)))
    (begin (printf "; Available commands:\n")
           (for-each (λ (c) (show-cmd c ";   ")) (reverse commands-list)))))

;; ----------------------------------------------------------------------------
;; generic commands

(defcommand (exit quit ex) "[<exit-code>]"
  "exit racket"
  ["Optional argument specifies exit code."]
  (cond [(getarg 'sexpr 'opt) => exit] [else (exit)]))

(define last-2dirs
  (make-parameter (let ([d (current-directory)]) (cons d d))))
(define (report-directory-change [mode #f])
  (define curdir (current-directory))
  (define (report) ; remove last "/" and say where we are
    (define-values [base name dir?] (split-path curdir))
    (printf "; now in ~a\n" (if base (build-path base name) curdir)))
  (cond [(not (equal? (car (last-2dirs)) curdir))
         (last-2dirs (cons curdir (car (last-2dirs))))
         (report)]
        [else (case mode
                [(pwd) (report)]
                [(cd)  (printf "; still in the same directory\n")])]))

(defcommand cd "[<path>]"
  "change the current directory"
  ["Sets `current-directory'; expands user paths.  With no arguments, goes"
   "to your home directory.  An argument of `-' indicates the previous"
   "directory."]
  (let* ([arg (or (getarg 'path 'opt) (find-system-path 'home-dir))]
         [arg (if (equal? arg (string->path "-")) (cdr (last-2dirs)) arg)])
    (if (directory-exists? arg)
      (begin (current-directory arg) (report-directory-change 'cd))
      (eprintf "cd: no such directory: ~a\n" arg))))

(defcommand pwd #f
  "read the current directory"
  ["Displays the value of `current-directory'."]
  (report-directory-change 'pwd))

(defcommand (shell sh ls cp mv rm md rd git svn) "<shell-command>"
  "run a shell command"
  ["`sh' runs a shell command (via `system'), the aliases run a few useful"
   "unix commands.  (Note: `ls' has some default arguments set.)"]
  (let* ([arg (getarg 'line)]
         [arg (if (equal? "" arg) #f arg)]
         [cmd (current-command)])
    (case cmd
      [(ls) (set! cmd "ls -F")]
      [(shell) (set! cmd 'sh)])
    (let ([cmd (cond [(eq? 'sh cmd) #f]
                     [(symbol? cmd) (symbol->string cmd)]
                     [else cmd])])
      (unless (system (cond [(and (not cmd) (not arg)) (getenv "SHELL")]
                            [(not cmd) arg]
                            [(not arg) cmd]
                            [else (string-append cmd " " arg)]))
        (eprintf "(exit with an error status)\n")))))

(defcommand (edit e) "<file> ..."
  "edit files in your $EDITOR"
  ["Runs your $EDITOR with the specified file/s.  If no files are given, and"
   "the REPL is currently inside a module, the file for that module is used."
   "If $EDITOR is not set, the ,drracket will be used instead."]
  (define env (let ([e (getenv "EDITOR")]) (and (not (equal? "" e)) e)))
  (define exe (and env (find-executable-path env)))
  (cond [(not env)
         (printf "~a, using the ,drracket command.\n"
                 (if env
                   (string-append "$EDITOR ("env") not found in your path")
                   "no $EDITOR variable"))
         (run-command 'drracket)]
        [(not (apply system* exe (getarg 'path* 'list)))
         (eprintf "(exit with an error status)\n")]
        [else (void)]))

(define ->running-dr #f)
(define (->dr . xs) (unless ->running-dr (start-dr)) (->running-dr xs))
(define (start-dr)
  (define c (make-custodian))
  (define ns ((dynamic-require 'racket/gui 'make-gui-namespace)))
  (parameterize ([current-custodian c]
                 [current-namespace ns]
                 [exit-handler (λ (x)
                                 (eprintf "DrRacket shutdown.\n")
                                 (set! ->running-dr #f)
                                 (custodian-shutdown-all c))])
    ;; construct a kind of a fake sandbox to run drracket in
    (define es
      (eval '(begin (require racket/class racket/gui framework racket/file)
                    (define es (make-eventspace))
                    es)))
    (define (E expr)
      (parameterize ([current-custodian c]
                     [current-namespace ns]
                     [(eval 'current-eventspace ns) es])
        (eval expr ns)))
    (E '(begin
          (define c (current-custodian))
          (define-syntax-rule (Q expr ...)
            (parameterize ([current-eventspace es])
              (queue-callback
               (λ () (parameterize ([current-custodian c]) expr ...)))))
          ;; problem: right after we read commands, readline will save a new
          ;; history in the prefs file which frequently collides with drr; so
          ;; make it use a writeback thing, with silent failures.  (actually,
          ;; this is more likely a result of previously starting drr wrongly,
          ;; but keep this anyway.)
          (let ([t (make-hasheq)] [dirty '()])
            (preferences:low-level-get-preference
             (λ (sym [dflt (λ () #f)])
               (hash-ref t sym
                 (λ () (let ([r (get-preference sym dflt)])
                         (hash-set! t sym r)
                         r)))))
            (preferences:low-level-put-preferences
             (λ (prefs vals)
               (Q (set! dirty (append prefs dirty))
                  (for ([pref (in-list prefs)] [val (in-list vals)])
                    (hash-set! t pref val)))))
            (define (flush-prefs)
              (set! dirty (remove-duplicates dirty))
              (with-handlers ([void void])
                (put-preferences dirty (map (λ (p) (hash-ref t p)) dirty))
                (set! dirty '())))
            (exit:insert-on-callback flush-prefs)
            (define (write-loop)
              (sleep (random 4))
              (when (pair? dirty) (Q (flush-prefs)))
              (write-loop))
            (define th (thread write-loop))
            (exit:insert-on-callback (λ () (Q (kill-thread th)))))
          ;; start it
          (Q (dynamic-require 'drracket #f))
          ;; hide the first untitled window, so drr runs in "server mode"
          (Q (dynamic-require 'drracket/tool-lib #f))
          (define top-window
            (let ([ch (make-channel)])
              (Q (let ([r (get-top-level-windows)])
                   (channel-put ch (and (pair? r) (car r)))))
              (channel-get ch)))
          (Q (when top-window (send top-window show #f))
             ;; and avoid trying to open new windows in there
             (send (group:get-the-frame-group) clear))
          ;; avoid being able to quit so the server stays running,
          ;; also hack: divert quitting into closing all group frames
          (define should-exit? #f)
          (exit:insert-can?-callback
           (λ () (or should-exit?
                     (let ([g (group:get-the-frame-group)])
                       (when (send g can-close-all?) (send g on-close-all))
                       #f))))
          (require drracket/tool-lib))) ; used as usual below
    (define (new)
      (E '(Q (drracket:unit:open-drscheme-window #f))))
    (define open
      (case-lambda
        [() (E '(Q (handler:open-file)))]
        [paths
         (let ([paths (map path->string paths)])
           (E `(Q (let ([f (drracket:unit:open-drscheme-window ,(car paths))])
                    (send f show #t)
                    ,@(for/list ([p (in-list (cdr paths))])
                        `(begin (send f open-in-new-tab ,p)
                                (send f show #t)))))))]))
    (define (quit)
      (E `(Q (set! should-exit? #t) (exit:exit))))
    (define (loop)
      (define m (thread-receive))
      (if (pair? m)
        (let ([proc (case (car m) [(new) new] [(open) open] [(quit) quit]
                          [else (cmderror "unknown flag: -~a" (car m))])])
          (if (procedure-arity-includes? proc (length (cdr m)))
            (apply proc (cdr m))
            (cmderror "bad number of arguments for the -~a flag" (car m))))
        (error '->dr "internal error"))
      (loop))
    (define th (thread loop))
    (set! ->running-dr (λ (xs) (thread-send th xs)))))
(defcommand (drracket dr drr) "[-flag] <file> ..."
  "edit files in DrRacket"
  ["Runs DrRacket with the specified file/s.  If no files are given, and"
   "the REPL is currently inside a module, the file for that module is used."
   "DrRacket is launched directly, without starting a new subprocess, and it"
   "is kept running in a hidden window so further invocations are immediate."
   "In addition to file arguments, the arguments can have a flag that"
   "specifies one of a few operations for the running DrRacket:"
   "* -new: opens a new editing window.  This is the default when no files are"
   "  given and the REPL is not inside a module,"
   "* -open: opens the specified file/s (or the current module's file).  This"
   "  is the default when files are given or when inside a module."
   "* -quit: exits the running instance.  Quitting the application as usual"
   "  will only close the visible window, but it will still run in a hidden"
   "  window.  This command should not be needed under normal circumstances."]
  (let ([args (getarg 'path* 'list)])
    (if (null? args)
      (->dr 'new)
      (let* ([cmd (let ([s (path->string (car args))])
                    (and (regexp-match? #rx"^-" s)
                         (string->symbol (substring s 1))))]
             [args (if cmd (cdr args) args)])
        (apply ->dr (or cmd 'open) args)))))

;; ----------------------------------------------------------------------------
;; binding related commands

(defcommand (apropos ap) "<search-for> ..."
  "look for a binding"
  ["Additional string arguments restrict matches shown.  The search specs can"
   "have symbols (which specify what to look for in bound names), and regexps"
   "(for more complicated matches)."]
  (let* ([look (map (λ (s) (cond [(symbol? s)
                                  (regexp (regexp-quote (symbol->string s)))]
                                 [(regexp? s) s]
                                 [else (cmderror "bad search spec: ~e" s)]))
                    (getarg 'sexpr 'list))]
         [look (and (pair? look)
                    (λ (str) (andmap (λ (rx) (regexp-match? rx str)) look)))]
         [syms (map (λ (sym) (cons sym (symbol->string sym)))
                    (namespace-mapped-symbols))]
         [syms (if look (filter (λ (s) (look (cdr s))) syms) syms)]
         [syms (sort syms string<? #:key cdr)]
         [syms (map car syms)])
    (if (null? syms)
      (printf "; No matches found")
      (parameterize ([wrap-prefix ";   "])
        (wprintf "; Matches: ~s" (car syms))
        (for ([s (in-list (cdr syms))]) (wprintf ", ~s" s))))
    (printf ".\n")))

(defcommand (describe desc id) "[<phase-number>] <identifier-or-module> ..."
  "describe a (bound) identifier"
  ["For a bound identifier, describe where is it coming from; for a known"
   "module, describe its imports and exports.  You can use this command with"
   "several identifiers.  An optional numeric argument specifies phase for"
   "identifier lookup."]
  (define-values [try-mods? level ids/mods]
    (let ([xs (getarg 'syntax 'list)])
      (if (and (pair? xs) (number? (syntax-e (car xs))))
        (values #f (syntax-e (car xs)) (cdr xs))
        (values #t 0 xs))))
  (for ([id/mod (in-list ids/mods)])
    (define dtm (syntax->datum id/mod))
    (define mod
      (and try-mods?
           (match dtm
             [(list 'quote (and sym (? module-name?))) sym]
             [(? module-name?) dtm]
             [_ (let ([x (with-handlers ([exn:fail? (λ (_) #f)])
                           (modspec->path dtm))])
                  (cond [(or (not x) (path? x)) x]
                        [(symbol? x) (and (module-name? x) `',x)]
                        [else (error 'describe "internal error: ~s" x)]))])))
    (define bind
      (cond [(identifier? id/mod) (identifier-binding id/mod level)]
            [mod #f]
            [else (cmderror "not an identifier or a known module: ~s" dtm)]))
    (define bind? (or bind (not mod)))
    (when bind? (describe-binding dtm bind level))
    (when mod   (describe-module dtm mod bind?))))
(define (describe-binding sym b level)
  (define at-phase (phase->name level " (~a)"))
  (cond
    [(not b)
     (printf "; `~s' is a toplevel (or unbound) identifier~a\n" sym at-phase)]
    [(eq? b 'lexical)
     (printf "; `~s' is a lexical identifier~a\n" sym at-phase)]
    [(or (not (list? b)) (not (= 7 (length b))))
     (cmderror "*** internal error, racket changed ***")]
    [else
     (define-values [src-mod src-id nominal-src-mod nominal-src-id
                     src-phase import-phase nominal-export-phase]
       (apply values b))
     (set! src-mod         (->relname (mpi->name src-mod)))
     (set! nominal-src-mod (->relname (mpi->name nominal-src-mod)))
     (printf "; `~s' is a bound identifier~a,\n" sym at-phase)
     (printf ";   defined~a in ~a~a\n" (phase->name src-phase "-~a") src-mod
             (if (not (eq? sym src-id)) (format " as `~s'" src-id) ""))
     (printf ";   required~a ~a\n" (phase->name import-phase "-~a")
             (if (equal? src-mod nominal-src-mod)
               "directly"
               (format "through \"~a\"~a"
                       nominal-src-mod
                       (if (not (eq? sym nominal-src-id))
                         (format " where it is defined as `~s'" nominal-src-id)
                         ""))))
     (printf "~a" (phase->name nominal-export-phase ";   (exported-~a)\n"))]))
(define (describe-module sexpr mod-path/sym also?)
  (define get
    (if (symbol? mod-path/sym)
      (let ([spec `',mod-path/sym])
        (λ (imp?) ((if imp? module->imports module->exports) spec)))
      (let ([code (get-module-code mod-path/sym)])
        (λ (imp?)
          ((if imp? module-compiled-imports module-compiled-exports) code)))))
  (define (phase<? p1 p2)
    (cond [(eq? p1 p2) #f]
          [(or (eq? p1 0) (not p2)) #t]
          [(or (eq? p2 0) (not p1)) #f]
          [(and (> p1 0) (> p2 0)) (< p1 p2)]
          [(and (< p1 0) (< p2 0)) (> p1 p2)]
          [else (> p1 0)]))
  (define (modname<? x y)
    (cond [(and (string? x) (string? y)) (string<? x y)]
          [(and (symbol? x) (symbol? y))
           (string<? (symbol->string x) (symbol->string y))]
          [(and (symbol? x) (string? y)) #t]
          [(and (string? x) (symbol? y)) #f]
          [else (error 'describe-module "internal error: ~s, ~s" x y)]))
  (define imports
    (filter-map
     (λ (x)
       (and (pair? (cdr x))
            (cons (car x) (sort (map (λ (m) (->relname (mpi->name m))) (cdr x))
                                modname<?))))
     (sort (get #t) phase<? #:key car)))
  (define-values [val-exports stx-exports]
    (let-values ([(vals stxs) (get #f)])
      (define (get-directs l)
        (filter-map
         (λ (x)
           (let ([directs (filter-map (λ (b) (and (null? (cadr b)) (car b)))
                                      (cdr x))])
             (and (pair? directs) (cons (car x) directs))))
         (sort l phase<? #:key car)))
      (values (get-directs vals) (get-directs stxs))))
  (printf "; `~a' is~a a module,\n" sexpr (if also? " also" ""))
  (let ([relname (->relname mod-path/sym)])
    (printf ";   ~a~a\n"
            (if (symbol? relname) "defined directly as '" "located at ")
            relname))
  (if (null? imports)
    (printf ";   no imports.\n")
    (parameterize ([wrap-prefix ";     "])
      (for ([imps (in-list imports)])
        (let ([phase (car imps)] [imps (cdr imps)])
          (wprintf ";   imports~a: ~a" (phase->name phase "-~a") (car imps))
          (for ([imp (in-list (cdr imps))]) (wprintf ", ~a" imp))
          (wprintf ".\n")))))
  (define (show-exports exports kind)
    (parameterize ([wrap-prefix ";   "])
      (for ([exps (in-list exports)])
        (let ([phase (car exps)] [exps (cdr exps)])
          (wprintf ";   direct ~a exports~a: ~a"
                   kind (phase->name phase "-~a") (car exps))
          (for ([exp (in-list (cdr exps))]) (wprintf ", ~a" exp))
          (wprintf ".\n")))))
  (if (and (null? val-exports) (null? stx-exports))
    (printf ";   no direct exports.\n")
    (begin (show-exports val-exports "value")
           (show-exports stx-exports "syntax"))))

(define help-id (make-lazy-identifier 'help 'racket/help))
(defcommand doc "<any> ..."
  "browse the racket documentation"
  ["Uses Racket's `help' to browse the documentation.  (Note that this can be"
   "used even in languages that don't have the `help' binding.)"]
  (eval-sexpr-for-user `(,(help-id) ,@(getarg 'syntax 'list))))

;; ----------------------------------------------------------------------------
;; require/load commands

(defcommand (require req r) "<module-spec> ...+"
  "require a module"
  ["The arguments are usually passed to `require', unless an argument"
   "specifies an existing filename -- in that case, it's like using a"
   "\"string\" or a (file \"...\") in `require'.  (Note: this does not"
   "work in subforms.)"]
  (more-inputs #`(require #,@(getarg 'modspec 'list+)))) ; use *our* `require'

(define rr-modules (make-hash)) ; hash to remember reloadable modules

(defcommand (require-reloadable reqr rr) "<module-spec> ...+"
  "require a module, make it reloadable"
  ["Same as ,require but the module is required in a way that makes it"
   "possible to reload later.  If it was already loaded then it is reloaded."
   "Note that this is done by setting `compile-enforce-module-constants' to"
   "#f, which prohibits some optimizations."]
  (parameterize ([compile-enforce-module-constants
                  (compile-enforce-module-constants)])
    (compile-enforce-module-constants #f)
    (for ([spec (in-list (getarg 'modspec 'list+))])
      (define datum    (syntax->datum spec))
      (define resolved ((current-module-name-resolver) datum #f #f #f))
      (define path     (resolved-module-path-name resolved))
      (if (hash-ref rr-modules resolved #f)
        ;; reload
        (begin (printf "; reloading ~a\n" path)
               (parameterize ([current-module-declare-name resolved])
                 (load/use-compiled path)))
        ;; require
        (begin (hash-set! rr-modules resolved #t)
               (printf "; requiring ~a\n" path)
               ;; (namespace-require spec)
               (eval #`(require #,spec)))))))

(define enter!-id (make-lazy-identifier 'enter! 'racket/enter))

(defcommand (enter en) "[<module-spec>] [noisy?]"
  "require a module and go into its namespace"
  ["Uses `enter!' to go into the module's namespace; the module name is"
   "optional, without it you go back to the toplevel.  A module name can"
   "specify an existing file as with the ,require command.  (Note that this"
   "can be used even in languages that don't have the `enter!' binding.)"]
  (eval-sexpr-for-user `(,(enter!-id) ,(getarg 'modspec)
                                      #:dont-re-require-enter)))

(defcommand (toplevel top) #f
  "go back to the toplevel"
  ["Go back to the toplevel, same as ,enter with no arguments."]
  (eval-sexpr-for-user `(,(enter!-id) #f)))

(defcommand (load ld) "<filename> ..."
  "load a file"
  ["Uses `load' to load the specified file(s)"]
  (more-inputs* (map (λ (name) #`(load #,name)) (getarg 'path 'list))))

;; ----------------------------------------------------------------------------
;; debugging commands

;; not useful: catches only escape continuations
;; (define last-break-exn (make-parameter #f))
;; (defcommand (continue cont) #f
;;   "continue from a break"
;;   ["Continue running from the last break."]
;;   (if (last-break-exn)
;;     ((exn:break-continuation (last-break-exn)))
;;     (cmderror 'continue "no break exception to continue from")))

(define time-id
  (make-lazy-identifier 'time* '(only-in unstable/time [time time*])))
(defcommand time "[<count>] <expr> ..."
  "time an expression"
  ["Times execution of an expression, similar to `time' but prints a"
   "little easier to read information.  You can provide an initial number"
   "that specifies how many times to run the expression -- in this case,"
   "the expression will be executed that many times, extreme results are"
   "be removed (top and bottom 2/7ths), and the remaining results will"
   "be averaged.  Two garbage collections are triggered before each run;"
   "the resulting value(s) are from the last run."]
  (more-inputs #`(#,(time-id) #,@(getarg 'syntax 'list))))

(define trace-id (make-lazy-identifier 'trace 'racket/trace))
(defcommand (trace tr) "<function> ..."
  "trace a function"
  ["Traces a function (or functions), using the `racket/trace' library."]
  (eval-sexpr-for-user `(,(trace-id) ,@(getarg 'syntax 'list))))

(define untrace-id (make-lazy-identifier 'untrace 'racket/trace))
(defcommand (untrace untr) "<function> ..."
  "untrace a function"
  ["Untraces functions that were traced with ,trace."]
  (eval-sexpr-for-user `(,(untrace-id) ,@(getarg 'syntax 'list))))

(defautoload errortrace
  profiling-enabled instrumenting-enabled clear-profile-results
  output-profile-results execute-counts-enabled annotate-executed-file)

(defcommand (errortrace errt inst) "[<flag>]"
  "errortrace instrumentation control"
  ["An argument is used to perform a specific operation:"
   "  + : turn errortrace instrumentation on (effective only for code that is"
   "      evaluated from now on)"
   "  - : turn it off (also only for future evaluations)"
   "  ? : show status without changing it"
   "With no arguments, toggles instrumentation."]
  (case (getarg 'sexpr 'opt)
    [(#f) (if (autoloaded? 'errortrace)
            (instrumenting-enabled (not (instrumenting-enabled)))
            (instrumenting-enabled #t))]
    [(-)  (when (autoloaded? 'errortrace) (instrumenting-enabled #f))]
    [(+)  (instrumenting-enabled #t)]
    [(?)  (void)]
    [else (cmderror "unknown subcommand")])
  (if (autoloaded? 'errortrace)
    (printf "; errortrace instrumentation is ~a\n"
            (if (instrumenting-enabled) "on" "off"))
    (printf "; errortrace not loaded\n")))

(define profile-id
  (make-lazy-identifier 'profile 'profile))
(define (statistical-profiler)
  (more-inputs #`(#,(profile-id) #,(getarg 'syntax))))
(define (errortrace-profiler)
  (instrumenting-enabled #t)
  (define flags (regexp-replace* #rx"[ \t]+" (getarg 'line) ""))
  (for ([cmd (in-string (if (equal? "" flags)
                          (if (profiling-enabled) "*!" "+")
                          flags))])
    (case cmd
      [(#\+) (profiling-enabled #t) (printf "; profiling is on\n")]
      [(#\-) (profiling-enabled #f) (printf "; profiling is off\n")]
      [(#\*) (output-profile-results #f #t)]
      [(#\#) (output-profile-results #f #f)]
      [(#\!) (clear-profile-results) (printf "; profiling data cleared\n")]
      [else (cmderror "unknown subcommand")])))
(defcommand (profile prof) "[<expr> | <flag> ...]"
  "profiler control"
  ["Runs either the exact errortrace-based profiler, or the statistical one."
   "* If a parenthesized expression is given, run the statistical profiler"
   "  while running it.  This profiler requires no special setup and adds"
   "  almost no overhead, it samples stack traces as execution goes on."
   "* Otherwise the errortrace profiler is used.  This profiler produces"
   "  precise results, but like other errortrace uses, it must be enabled"
   "  before loading the code and it adds noticeable overhead.  In this case,"
   "  an argument is used to determine a specific operation:"
   "  + : turn the profiler on (effective only for code that is evaluated"
   "      from now on)"
   "  - : turn the profiler off (also only for future evaluations)"
   "  * : show profiling results by time"
   "  # : show profiling results by counts"
   "  ! : clear profiling results"
   "  Multiple commands can be combined, for example \",prof *!-\" will show"
   "  profiler results, clear them, and turn it off."
   "* With no arguments, turns the errortrace profiler on if it's off, and if"
   "  it's on it shows the collected results and clears them."
   "Note: using no arguments or *any* of the flags turns errortrace"
   "  instrumentation on, even a \",prof -\".  Use the ,errortrace command if"
   "  you want to turn instrumentation off."]
  (if (memq (skip-spaces/peek) '(#\( #\[ #\{))
    (statistical-profiler)
    (errortrace-profiler)))

(defcommand execution-counts "<file> ..."
  "execution counts"
  ["Enable errortrace instrumentation for coverage, require the file(s),"
   "display the results, disables coverage, and disables instrumentation if"
   "it wasn't previously turned on."]
  (let ([files (getarg 'path 'list)]
        [inst? (and (autoloaded? 'errortrace) (instrumenting-enabled))])
    (more-inputs
     (λ ()
       (instrumenting-enabled #t)
       (execute-counts-enabled #t))
     #`(require #,@(map (λ (file) `(file ,(path->string file))) files))
     (λ ()
       (for ([file (in-list files)])
         (annotate-executed-file file " 123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")))
     (λ ()
       (execute-counts-enabled #f)
       (unless inst? (instrumenting-enabled #f))))))

(defautoload racket/sandbox
  make-module-evaluator kill-evaluator call-with-trusted-sandbox-configuration
  sandbox-coverage-enabled get-uncovered-expressions)

(defcommand (coverage cover) "<file>"
  "coverage information via a sandbox"
  ["Runs the given file in a (trusted) sandbox, and annotates it with"
   "uncovered expression information."]
  (let ([file (getarg 'path)])
    (sandbox-coverage-enabled) ; autoload it
    (parameterize ([sandbox-coverage-enabled #t])
      (define e
        (call-with-trusted-sandbox-configuration
         (λ () (make-module-evaluator file))))
      (define uncovered
        (map (λ (x) (let ([p (sub1 (syntax-position x))])
                      (cons p (+ p (syntax-span x)))))
             (get-uncovered-expressions e #t)))
      (kill-evaluator e)
      (call-with-input-file file
        (λ (inp)
          ;; this is a naive and inefficient solution, could be made efficient
          ;; using `mzlib/integer-set'
          (let loop ()
            (let* ([start  (file-position inp)]
                   [line   (read-line inp)]
                   [len    (and (string? line) (string-length line))]
                   [end    (and len (+ len start))]
                   [indent (and len (regexp-match-positions #px"\\S" line))]
                   [indent (and indent (caar indent))])
              (when len
                (displayln line)
                (when indent
                  (string-fill! line #\space)
                  (for ([u (in-list uncovered)])
                    (when (and ((car u) . < . end)
                               ((cdr u) . > . indent))
                      (for ([i (in-range (max (- (car u) start) indent)
                                         (min (- (cdr u) start) len))])
                        (string-set! line i #\^))))
                  (displayln (regexp-replace #rx" +$" line "")))
                (loop)))))))))

;; ----------------------------------------------------------------------------
;; namespace switching

(define default-namespace-name '*)
(define current-namespace-name (make-parameter default-namespace-name))
(define namespaces
  (let* ([r (namespace-symbol->identifier '#%top-interaction)]
         [r (identifier-binding r)]
         [r (and r (mpi->name (caddr r)))]
         [t (make-hasheq)])
    (hash-set! t (current-namespace-name) (cons (current-namespace) r))
    t))
(defcommand (switch-namespace switch) "[<name>] [! [<init>]]"
  "switch to a different repl namespace"
  ["Switch to the <name> namespace, creating it if needed.  The <name> of a"
   "namespace is a symbol or an integer where a `*' indicates the initial one;"
   "it is only used to identify namespaces for this command (so don't confuse"
   "it with racket bindings).  A new namespace is initialized using the name"
   "of the namespace (if it's require-able), or using the same initial module"
   "that was used for the current namespace.  If `! <init>' is used, it"
   "indicates that a new namespace will be created even if it exists, using"
   "`<init>' as the initial module, and if just `!' is used, then this happens"
   "with the existing namespace's init or with the current one's."
   "A few examples:"
   "  ,switch !             reset the current namespace"
   "  ,switch ! racket      reset it using the `racket' language"
   "  ,switch r5rs          switch to a new `r5rs' namespace"
   "  ,switch foo           switch to `foo', creating it if it doesn't exist"
   "  ,switch foo ! racket  switch to newly made `foo', even if it exists"
   "  ,switch foo !         same, but using the same <init> as it was created"
   "                        with, or same as the current if it's new"
   "(Note that you can use `^' etc to communicate values between namespaces.)"]
  (define-values (name force-reset? init)
    (match (getarg 'sexpr 'list)
      [(list '!)           (values #f   #t #f  )]
      [(list '! init)      (values #f   #t init)]
      [(list name)         (values name #f #f  )]
      [(list name '!)      (values name #t #f  )]
      [(list name '! init) (values name #t init)]
      [(list) (cmderror "what do you want to do?")]
      [_      (cmderror "syntax error, see ,help switch-namespace")]))
  (unless (or (not name) (symbol? name) (fixnum? name))
    (cmderror "bad namespace name, must be symbol or fixnum"))
  (define old-namespace (current-namespace))
  (define (is-require-able? name)
    (with-handlers ([void (λ (_) #f)])
      ;; name is not a string => no need to set the current directory
      (file-exists? (modspec->path name))))
  ;; if there's an <init>, then it must be forced
  (let* ([name (or name (current-namespace-name))]
         [init
          (cond [init]
                [(or force-reset? (not (hash-ref namespaces name #f)))
                 (cdr (or (hash-ref namespaces name #f)
                          (and (is-require-able? name) (cons #f name))
                          (hash-ref namespaces (current-namespace-name) #f)
                          ;; just in case
                          (hash-ref namespaces default-namespace-name #f)))]
                [else #f])])
    (when init
      (printf "*** ~a `~s' namespace with ~s ***\n"
              (if (hash-ref namespaces name #f)
                "Resetting the" "Initializing a new")
              name
              (->relname init))
      (current-namespace (make-base-empty-namespace))
      (namespace-require init)
      (hash-set! namespaces name (cons (current-namespace) init))))
  (when (and name (not (eq? name (current-namespace-name))))
    (printf "*** switching to the `~s' namespace ***\n" name)
    (let ([x (hash-ref namespaces (current-namespace-name))])
      (unless (eq? (car x) old-namespace)
        (printf "*** (note: saving current namespace for `~s')\n"
                (current-namespace-name))
        (hash-set! namespaces (current-namespace-name)
                   (cons old-namespace (cdr x)))))
    (current-namespace-name name)
    (current-namespace (car (hash-ref namespaces name)))))

;; ----------------------------------------------------------------------------
;; syntax commands

(define current-syntax (make-parameter #f))
(defautoload racket/pretty pretty-write)
(defautoload macro-debugger/stepper-text expand/step-text)
(define not-in-base
  (λ () (let ([base-stxs #f])
          (unless base-stxs
            (set! base-stxs ; all ids that are bound to a syntax in racket/base
                  (parameterize ([current-namespace (here-namespace)])
                    (let-values ([(vals stxs) (module->exports 'racket/base)])
                      (map (λ (s) (namespace-symbol->identifier (car s)))
                           (cdr (assq 0 stxs)))))))
          (λ (id) (not (ormap (λ (s) (free-identifier=? id s)) base-stxs))))))
(defcommand (syntax stx st) "[<expr>] [<flag> ...]"
  "set syntax object to inspect, and control it"
  ["With no arguments, will show the previously set (or expanded) syntax"
   "additional arguments serve as an operation to perform:"
   "- `^' sets the syntax from the last entered expression"
   "- `+' will `expand-once' the syntax and show the result (can be used again"
   "      for additional `expand-once' steps)"
   "- `!' will `expand' the syntax and show the result"
   "- `*' will use the syntax stepper to show expansion steps, leaving macros"
   "      from racket/base intact (does not change the currently set syntax)"
   "- `**' similar to `*', but expanding everything"]
  (for ([stx (in-list (getarg 'syntax 'list))])
    (define (show/set label stx)
      (printf "~a\n" label)
      (current-syntax stx)
      (pretty-write (syntax->datum stx)))
    (define (cur) (or (current-syntax) (cmderror "no syntax set yet")))
    (case (and stx (if (identifier? stx) (syntax-e stx) '--none--))
      [(#f) (show/set "current syntax:" (cur))]
      [(^)  (if (last-input-syntax)
              (show/set "using last expression:" (last-input-syntax))
              (cmderror "no expression entered yet"))]
      [(+)  (show/set "expand-once ->" (expand-once (cur)))]
      [(!)  (show/set "expand ->" (expand (cur)))]
      [(*)  (printf "stepper:\n") (expand/step-text (cur) (not-in-base))]
      [(**) (printf "stepper:\n") (expand/step-text (cur))]
      [else
       (if (syntax? stx)
         (begin (printf "syntax set\n") (current-syntax stx))
         (cmderror "internal error: ~s ~s" stx (syntax? stx)))])))

;; ----------------------------------------------------------------------------
;; meta evaluation hook

;; questionable value, (and need to display the resulting values etc)
#;
(defcommand meta "<expr>"
  "meta evaluation"
  ["Evaluate the given expression where bindings are taken from the xrepl"
   "module.  This is convenient when you're in a namespace that does not have"
   "a specific binding -- for example, you might be using a language that"
   "doesn't have `current-namespace', so to get it, you can use"
   "`,eval (current-namespace)'.  The evaluation happens in the repl namespace"
   "as usual, only the bindings are taken from the xrepl module -- so you can"
   "use `^' to refer to the result of such an evaluation."]
  (eval (datum->syntax #'here `(#%top-interaction . ,(getarg 'sexpr))))
  (void))

;; ----------------------------------------------------------------------------
;; dynamic log output control

(define current-log-receiver-thread (make-parameter #f))
(define global-logger (current-logger))

(defcommand log "<level>"
  "control log output"
  ["Starts (or stops) logging events at the given level.  The level should be"
   "one of the valid racket logging levels, or #f for no logging.  For"
   "convenience, the level can also be #t (maximum logging) or an integer"
   "(with 0 for no logging, and larger numbers for more logging output)."]
  (define levels '(#f fatal error warning info debug))
  (define level
    (let ([l (getarg 'sexpr)])
      (cond [(memq l levels) l]
            [(memq l '(#f none -)) #f]
            [(memq l '(#t all +)) (last levels)]
            [(not (integer? l))
             (cmderror "bad level, expecting one of: ~s" levels)]
            [(<= l 0) #f]
            [(< l (length levels)) (list-ref levels l)]
            [else (last levels)])))
  (cond [(current-log-receiver-thread) => kill-thread])
  (when level
    (let ([r (make-log-receiver global-logger level)])
      (current-log-receiver-thread
       (thread
        (λ ()
          (let loop ()
            (match (sync r)
              [(vector l m v)
               (display (format "; [~a] ~a~a\n"
                                l m (if v (format " ~.s" v) "")))
               (flush-output)])
            (loop))))))))

;; ----------------------------------------------------------------------------
;; setup xrepl in the user's racketrc file

(define init-file (find-system-path 'init-file))
(defcommand install! #f
  "install xrepl in your Racket init file"
  ["Installs xrepl in your Racket REPL initialization file.  This is done"
   "carefully: I will tell you about the change, and ask for permission."
   "You can then edit the file if you want to; in your system, you can find it"
   ,(format "at \"~a\"." init-file)]
  (define comment "The following line loads `xrepl' support")
  (define expr  "(require xrepl)")
  (define dexpr "(dynamic-require 'xrepl #f)")
  (define contents (file->string init-file))
  (define (look-for comment-rx expr)
    (let ([m (regexp-match-positions
              (format "(?<=\r?\n|^) *;+ *~a *\r?\n *~a *(?=\r?\n|$)"
                      comment-rx (regexp-quote expr))
              contents)])
      (and m (car m))))
  (define existing? (look-for (regexp-quote comment) expr))
  (define existing-readline?
    (look-for "load readline support[^\r\n]*" "(require readline/rep)"))
  (define (yes?)
    (flush-output)
    (begin0 (regexp-match? #rx"^[yY]" (getarg 'string)) (prompt-shown)))
  (cond
    [existing?
     (printf "; already installed, nothing to do\n")
     (when existing-readline?
       (printf "; (better to remove the readline loading, xrepl does that)"))]
    [(let ([m (regexp-match
               (string-append (regexp-quote expr) "|" (regexp-quote dexpr))
               contents)])
       (and m (begin (printf "; found \"~a\", ~a\n"
                             (car m) "looks like xrepl is already installed")
                     (printf "; should I continue anyway? ")
                     (not (yes?)))))]
    [else
     (when existing-readline?
       (printf "; found a `readline' loading line\n")
       (printf "; xrepl will already do that, ok to remove? ")
       (if (yes?)
         (set! contents (string-append
                         (substring contents 0 (car existing-readline?))
                         (substring contents (cdr existing-readline?))))
         (printf "; it will be kept ~a\n"
                 "(you can edit the file and removing it later)")))
     (printf "; writing new contents, with an added \"~a\"\n" expr)
     (printf "; (if you want to load it conditionally, edit the file and\n")
     (printf ";  use \"~a\" instead, which is a plain expression)\n" dexpr)
     (printf "; OK to continue? ")
     (if (yes?)
       (begin
         (call-with-output-file* init-file #:exists 'truncate
           (λ (o) (write-string
                   (string-append (regexp-replace #rx"(?:\r?\n)+$" contents "")
                                  (format "\n\n;; ~a\n~a\n" comment expr))
                   o)))
         (printf "; new contents written to ~a\n" init-file))
       (printf "; ~a was not updated\n" init-file))])
  (void))

;; ----------------------------------------------------------------------------
;; eval hook that keep track of recent evaluation results

;; saved interaction values
(define saved-values (make-parameter '()))
(define (save-values! xs)
  (let ([xs (filter (λ (x) (not (void? x))) xs)]) ; don't save void values
    (unless (null? xs)
      ;; the order is last, 2nd-to-last, ..., same from prev interactions
      ;; the idea is that `^', `^^', etc refer to the values as displayed
      (saved-values (append (reverse xs) (saved-values)))
      (let ([n (saved-values-number)] [l (saved-values)])
        (when (< n (length l)) (saved-values (take l n)))))))

(define last-saved-names+state (make-parameter '(#f #f #f)))
(define (get-saved-names)
  (define last      (last-saved-names+state))
  (define last-num  (cadr last))
  (define last-char (caddr last))
  (define cur-num   (saved-values-number))
  (define cur-char  (saved-values-char))
  (if (and (equal? last-num cur-num) (equal? last-char cur-char))
    (car last)
    (let ([new (for/list ([i (in-range (saved-values-number))])
                 (string->symbol (make-string (add1 i) (saved-values-char))))])
      (last-saved-names+state (list new cur-num cur-char))
      new)))

;; make saved values available through bindings, but do this in a way that
;; doesn't interfere with users using these binders in some way -- set only ids
;; that were void, and restore them to void afterwards
(define (with-saved-values thunk)
  (define saved-names (get-saved-names))
  (define vals (for/list ([id (in-list saved-names)])
                 (box (namespace-variable-value id #f void))))
  (define res #f)
  (dynamic-wind
    (λ ()
      (for ([id    (in-list saved-names)]
            [saved (in-list (saved-values))]
            [v     (in-list vals)])
        ;; set only ids that are void, and remember these values
        (if (void? (unbox v))
          (begin (namespace-set-variable-value! id saved)
                 (set-box! v saved))
          (set-box! v (void)))))
    (λ () (call-with-values thunk (λ vs (set! res vs) (apply values vs))))
    (λ ()
      (for ([id (in-list saved-names)] [v (in-list vals)])
        ;; restore the names to void so we can set them next time
        (when (and (not (void? (unbox v))) ; restore if we set this id above
                   (eq? (unbox v) ; and if it didn't change
                        (namespace-variable-value id #f void)))
          (namespace-set-variable-value! id (void))))
      (when res (save-values! res)))))

(provide make-command-evaluator)
(define (make-command-evaluator builtin-evaluator)
  (λ (expr)
    ;; not useful: catches only escape continuations
    ;; (with-handlers ([exn:break? (λ (e) (last-break-exn e) (raise e))]) ...)
    (if (saved-values)
      (with-saved-values (λ () (builtin-evaluator expr)))
      (builtin-evaluator expr))))

;; ----------------------------------------------------------------------------
;; capture ",..." and run the commands, use readline/rep when possible

(define home-dir (expand-user-path "~"))
(define get-prefix ; to show before the "> " prompt
  (let ()
    (define (choose-path x)
      ;; choose the shortest from an absolute path, a relative path, and a
      ;; "~/..." path.
      (if (not (complete-path? x)) ; shouldn't happen
        x
        (let* ([r (path->string (find-relative-path (current-directory) x))]
               [h (path->string (build-path (string->path-element "~")
                                            (find-relative-path home-dir x)))]
               [best (if (< (string-length r) (string-length h)) r h)]
               [best (if (< (string-length best) (string-length x)) best x)])
          best)))
    (define (get-prefix* path)
      (define x (path->string path))
      (define y (->relname path))
      (if (equal? x y)
        (format "~s" (choose-path x))
        (regexp-replace #rx"[.]rkt$" y "")))
    (define (get-prefix)
      (let* ([x (here-source)]
             [x (and x (if (symbol? x) (format "'~s" x) (get-prefix* x)))]
             [x (or x (toplevel-prefix))])
        (if (eq? (current-namespace-name) default-namespace-name)
          x (format "~a::~a" (current-namespace-name) x))))
    (define last-directory #f)
    (define last-namespace #f)
    (define prefix #f)
    (λ ()
      (define curdir (current-directory))
      (unless (and (equal? (current-namespace) last-namespace)
                   (equal? curdir last-directory))
        (report-directory-change)
        (set! prefix (get-prefix))
        (set! last-namespace (current-namespace))
        (set! last-directory curdir))
      prefix)))

;; the last non-command expression read
(define last-input-syntax (make-parameter #f))

(struct more-inputs (list)
        #:constructor-name more-inputs* #:omit-define-syntaxes)
(define (more-inputs . inputs) (more-inputs* inputs))

(provide make-command-reader)
(define (make-command-reader)
  (define (plain-reader prefix) ; a plain reader, without readline
    (display prefix) (display "> ") (flush-output)
    (let ([in ((current-get-interaction-input-port))])
      ((current-read-interaction) (object-name in) in)))
  (define RL ; no direct dependency on readline
    (with-handlers ([exn? (λ (_) #f)])
      (collection-file-path "pread.rkt" "readline")))
  (define (make-readline-reader)
    (let ([p (dynamic-require RL 'current-prompt)]
          [r (dynamic-require RL 'read-cmdline-syntax)])
      (λ (prefix) ; uses the readline prompt
        (parameterize ([p (bytes-append (string->bytes/locale prefix) (p))])
          (r)))))
  (define reader
    (case (object-name (current-input-port))
      [(stdin)
       (if (or (not (terminal-port? (current-input-port)))
               (regexp-match? #rx"^dumb" (or (getenv "TERM") ""))
               (not RL))
         plain-reader
         (with-handlers ([exn?
                          (λ (e)
                            (eprintf "Warning: no readline support (~a)\n"
                                     (exn-message e))
                            plain-reader)])
           (dynamic-require 'readline/rep-start #f)
           ;; requiring readline should have changed the reader
           (if (eq? (current-prompt-read)
                    (dynamic-require RL 'read-cmdline-syntax))
             (make-readline-reader)
             (begin (eprintf "Warning: could not initialize readline\n")
                    plain-reader))))]
      [(readline-input)
       (eprintf "Note: readline already loaded\n~a\n"
                "  (better to let xrepl load it for you)")
       (make-readline-reader)]
      [else plain-reader]))
  ;; IO management
  (port-count-lines! (current-input-port))
  ;; wrap the reader to get the command functionality
  (define more-inputs '())
  (define (reader-loop)
    (parameterize ([saved-values #f])
      (define from-queue? (pair? more-inputs))
      (define input
        (if from-queue?
          (begin0 (car more-inputs) (set! more-inputs (cdr more-inputs)))
          (begin (fresh-line) (begin0 (reader (get-prefix)) (prompt-shown)))))
      (syntax-case input ()
        [(uq cmd) (eq? 'unquote (syntax-e #'uq))
         (let ([r (run-command (syntax->datum #'cmd))])
           (cond [(void? r) (reader-loop)]
                 [(more-inputs? r)
                  (set! more-inputs (append (more-inputs-list r) more-inputs))
                  (reader-loop)]
                 [else (eprintf "Warning: internal weirdness: ~s\n" r) r]))]
        [_ (begin (unless from-queue? (last-input-syntax input)) input)])))
  reader-loop)
