#lang scheme/base

(require "syntax.rkt"
         ffi/unsafe/atomic
         racket/flonum
         ffi/unsafe
         ffi/unsafe/atomic
         racket/math
         racket/class
         "hold.ss"
         "local.ss"
         "../unsafe/cairo.ss"
         "../unsafe/pango.ss"
         "color.ss"
         "pen.ss"
         "brush.ss"
         "font.ss"
         "bitmap.ss"
         "region.ss"
         "dc-intf.ss"
         "dc-path.ss"
         "point.ss"
         "local.ss"
         "../unsafe/bstr.rkt")

(provide dc-mixin
         dc-backend<%>
         default-dc-backend%
         install-bitmap-dc-class!
         do-set-pen!
         do-set-brush!)

(define-local-member-name
  do-set-pen!
  do-set-brush!)

(define 2pi (* 2 pi))

(define (copy-color c)
  (if (send c is-immutable?)
      c
      (let ([c (make-object color% 
                            (color-red c) 
                            (color-green c) 
                            (color-blue c))]) 
        (send c set-immutable)
        c)))

(define -bitmap-dc% #f)
(define (install-bitmap-dc-class! v) (set! -bitmap-dc% v))

(define (transformation-vector? v)
  (and (vector? v)
       (= 6 (vector-length v))
       (matrix-vector? (vector-ref v 0))
       (real? (vector-ref v 1))
       (real? (vector-ref v 2))
       (real? (vector-ref v 3))
       (real? (vector-ref v 4))
       (real? (vector-ref v 5))))

(define substitute-fonts? (memq (system-type) '(macosx)))
(define substitute-mapping (make-hasheq))

;; dc-backend : interface
;;
;; This is the interface that the backend specific code must implement
(define dc-backend<%>
  (interface ()
    ;; get-cr : -> cairo_t or #f
    ;;
    ;; Gets a cairo_t created in a backend specific manner.
    ;; We assume that no one else is using this Cairo context
    ;; or its surface (i.e., no state will change out from user us,
    ;; and our state won't bother anyone else).
    get-cr

    ;; release-cr : cairo_t -> void
    ;;
    ;; Stops using a cairo_t obtained by a get-cr
    release-cr

    ;; Ends a document
    end-cr

    ;; Overriden here; to be called by a back-end when the Cairo
    ;; context changes
    reset-cr
    
    ;; method flush-cr : -> void
    ;;
    ;; Queues a flushes for the context to show drawing.
    ;; May assume create-context has
    ;; been called before any call to flush.
    flush-cr

    ;; method init-cr-matrix : -> void
    ;;
    ;; Initializes/resets the transformation matrix
    init-cr-matrix

    ;; method reset-clip : cr -> void
    ;;
    ;; Resets the clipping region
    reset-clip

    ;; method get-pango : -> pango_font_desc
    ;; 
    ;; Gets a Pango font description for a given font
    get-pango

    ;; method collapse-bitmap-b&w? : -> boolean
    ;;
    ;; triggers special handling of bitmap copies to a b&w target
    collapse-bitmap-b&w?

    ;; method get-font-metrics-key : real real -> integer
    ;; 
    ;; Gets a font-merics key for the current scale. 0 is always a 
    ;; safe result, but the default is to return 1 for an unscaled
    ;; dc.
    get-font-metrics-key

    ;; dc-adjust-smoothing
    ;; 
    ;; Used to keep smoothing disabled for b&w contexts
    dc-adjust-smoothing

    ;; The public get-size method:
    get-size

    ;; set-auto-scroll : real real -> void
    ;;
    ;; used by a back-end to install canvas scrolling
    set-auto-scroll

    ;; can-combine-text? : real -> bool
    ;;
    ;; Return #t if text at given font size (already scaled)
    ;;  looks good when drawn all at once (which allows kerning,
    ;;  but may be spaced weirdly)
    can-combine-text?

    ;; can-mask-bitmap? : -> bool
    ;;
    ;; Return #t if bitmap drawing with a mask is supported.
    ;; It's not supported for PostScirpt output, for example.
    can-mask-bitmap?

    ;; erase : -> void
    ;; A public method: erases all drawing
    erase))

(define default-dc-backend%
  (class* object% (dc-backend<%>)

    (define/public (get-cr) #f)
    (define/public (release-cr cr) (void))
    (define/public (end-cr) (void))
    (define/public (reset-cr) (void))
    
    (define/public (flush-cr) (void))

    (define/public (init-cr-matrix cr) (void))

    (define/public (reset-clip cr)
      (cairo_reset_clip cr))

    (define/public (get-pango font)
      (send font get-pango))

    (define/public (get-font-metrics-key sx sy)
      (if (and (= sx 1.0) (= sy 1.0))
          1
          0))

    (define/public (ok?) #t)

    (define/public (dc-adjust-smoothing s) s)

    (define/public (install-color cr c a)
      (let ([norm (lambda (v) (/ v 255.0))])
        (cairo_set_source_rgba cr
                               (norm (color-red c))
                               (norm (color-green c))
                               (norm (color-blue c))
                               a)))

    (define/public (collapse-bitmap-b&w?) #f)

    (define/public (get-size) (values 0.0 0.0))

    (define/public (set-auto-scroll dx dy) (void))

    (define/public (can-combine-text? sz)
      (sz . > . 32.0))

    (define/public (can-mask-bitmap?)
      #t)

    (define/public (erase)
      (void))

    (define/public (get-gl-context)
      #f)

    (super-new)))

(define hilite-color (send the-color-database find-color "black"))
(define hilite-alpha 0.3)

(define-local-member-name
  draw-bitmap-section/mask-offset)

;; We make different font map for each smoothing
;; kind because the smoothing choice the first
;; time a font is used in a given map seems to stick,
;; at least for the Quartz and Win32 back-ends.
;; (But we create the font maps on demand.)
(define font-maps (make-vector 4 #f))

(define (dc-mixin backend%)
  (defclass* dc% backend% (dc<%>)
    (super-new)

    (inherit flush-cr get-cr release-cr end-cr init-cr-matrix get-pango
             install-color dc-adjust-smoothing reset-clip
             collapse-bitmap-b&w?
             ok? can-combine-text? can-mask-bitmap?)

    ;; Using the global lock here is troublesome, becase
    ;; operations involving paths, regions, and text can
    ;; take arbitrarily long. Parts of the editor infrastructure,
    ;; meanwhile, assume that the global lock can be taken
    ;; around actions that use the editor-canvas dc. If we
    ;; have a separate per-dc lock, we can hit deadlock due to
    ;; lock order.

    (define-syntax-rule (with-cr default cr . body)
      ;; Faster:
      (begin
        (start-atomic)
        (let ([cr (get-cr)])
          (if cr 
              (begin0
                (begin . body)
                (release-cr cr)
                (end-atomic))
              (begin
                (end-atomic)
                default))))
      ;; Safer:
      #;
      (call-as-atomic
       (lambda ()
         (let ([cr (get-cr)])
           (if cr 
	       (dynamic-wind
		   void
		   (lambda () . body) 
		   (lambda () (release-cr cr)))
               default)))))

    (define/public (in-cairo-context cb)
      (with-cr (void) cr (cb cr)))

    ;; pango contexts, one per smoothing kind:
    (define contexts (make-vector (vector-length font-maps) #f))
    (define desc-layoutss (make-vector (vector-length font-maps) #f))

    (define black (send the-color-database find-color "black"))
    (define pen (send the-pen-list find-or-create-pen "black" 1 'solid))
    (define brush (send the-brush-list find-or-create-brush "white" 'solid))
    (define font (send the-font-list find-or-create-font 12 'default))
    (define text-fg (send the-color-database find-color "black"))
    (define text-bg (send the-color-database find-color "white"))
    (define text-mode 'transparent)
    (define bg (send the-color-database find-color "white"))
    (define pen-stipple-s #f)
    (define brush-stipple-s #f)

    (define x-align-delta 0.5)
    (define y-align-delta 0.5)
    (define/private (reset-align!)
      (let ([w (send pen get-width)])
        (if (zero? w)
            (begin
              (set! x-align-delta 0.5)
              (set! y-align-delta 0.5))
            (begin
              (set! x-align-delta (/ (bitwise-and 1 (max 1 (inexact->exact (floor (* effective-scale-x w))))) 2.0))
              (set! y-align-delta (/ (bitwise-and 1 (max 1 (inexact->exact (floor (* effective-scale-y w))))) 2.0))))))

    (def/public (set-font [font% f])
      (set! font f))

    (def/public (get-font) font)

    (define matrix (make-cairo_matrix_t 1 0 0 1 0 0))
    (define origin-x 0.0)
    (define origin-y 0.0)
    (define scale-x 1.0)
    (define scale-y 1.0)
    (define rotation 0.0)

    (define scroll-dx 0.0)
    (define scroll-dy 0.0)

    (define effective-scale-x 1.0)
    (define effective-scale-y 1.0)
    (define effective-origin-x 0.0)
    (define effective-origin-y 0.0)

    (define current-xform (vector 1.0 0.0 0.0 1.0 0.0 0.0))

    (define/private (reset-effective!)
      (let* ([mx (make-cairo_matrix_t 1 0 0 1 0 0)])
        (cairo_matrix_multiply mx mx matrix)
        (cairo_matrix_translate mx origin-x origin-y)
        (cairo_matrix_scale mx scale-x scale-y)
        (cairo_matrix_rotate mx (- rotation))
        (set! effective-scale-x (cairo_matrix_t-xx mx))
        (set! effective-scale-y (cairo_matrix_t-yy mx))
        (set! effective-origin-x (cairo_matrix_t-x0 mx))
        (set! effective-origin-y (cairo_matrix_t-y0 mx))
        (let ([v (vector (cairo_matrix_t-xx mx)
                         (cairo_matrix_t-yx mx)
                         (cairo_matrix_t-xy mx)
                         (cairo_matrix_t-yy mx)
                         (cairo_matrix_t-x0 mx)
                         (cairo_matrix_t-y0 mx))])
          (unless (equal? v current-xform)
            (set! current-xform v)))))

    (define/override (set-auto-scroll dx dy)
      (unless (and (= scroll-dx (- dx))
                   (= scroll-dy (- dy)))
        (set! scroll-dx (- dx))
        (set! scroll-dy (- dy))
        (reset-matrix)))

    (def/public (set-scale [real? sx] [real? sy])
      (unless (and (equal? scale-x sx)
                   (equal? scale-y sy))
        (set! scale-x sx)
        (set! scale-y sy)
        (reset-effective!)
        (reset-align!)
        (reset-matrix)))
    (def/public (get-scale) (values scale-x scale-y))

    (def/public (set-origin [real? ox] [real? oy])
      (unless (and (equal? origin-x ox)
                   (equal? origin-y oy))
        (set! origin-x ox)
        (set! origin-y oy)
        (reset-effective!)
        (reset-matrix)))
    (def/public (get-origin) 
      (values origin-x origin-y))

    (def/public (set-rotation [real? th])
      (unless (and (equal? rotation th))
        (set! rotation th)
        (reset-effective!)
        (reset-matrix)))
    (def/public (get-rotation) rotation)

    (def/public (translate [real? ox] [real? oy])
      (transform (vector 1 0 0 1 ox oy)))
    (def/public (scale [real? sx] [real? sy])
      (transform (vector sx 0 0 sy 0 0)))
    (def/public (rotate [real? theta])
      (let ([s (sin (- theta))]
            [c (cos (- theta))])
        (transform (vector c s (- s) c 0 0))))

    (def/public (transform [matrix-vector? mi])
      (let* ([m matrix]
             [mx (make-cairo_matrix_t 1 0 0 1 0 0)]
             [mx2 (make-cairo_matrix_t (vector-ref mi 0)
                                       (vector-ref mi 1)
                                       (vector-ref mi 2)
                                       (vector-ref mi 3)
                                       (vector-ref mi 4)
                                       (vector-ref mi 5))])
        (cairo_matrix_multiply mx mx m)
        (cairo_matrix_translate mx origin-x origin-y)
        (cairo_matrix_scale mx scale-x scale-y)
        (cairo_matrix_rotate mx (- rotation))
        (cairo_matrix_multiply mx mx mx2)
        (set! origin-x 0.0)
        (set! origin-y 0.0)
        (set! scale-x 1.0)
        (set! scale-y 1.0)
        (set! rotation 0.0)
        (set! matrix mx)
        (reset-matrix)))

    (def/public (set-initial-matrix [matrix-vector? m])
      (set! matrix (make-cairo_matrix_t (vector-ref m 0)
                                        (vector-ref m 1)
                                        (vector-ref m 2)
                                        (vector-ref m 3)
                                        (vector-ref m 4)
                                        (vector-ref m 5)))
      (reset-effective!)
      (reset-align!)
      (reset-matrix))

    (def/public (get-initial-matrix)
      (let ([m matrix])
        (vector-immutable (cairo_matrix_t-xx m)
                          (cairo_matrix_t-yx m)
                          (cairo_matrix_t-xy m)
                          (cairo_matrix_t-yy m)
                          (cairo_matrix_t-x0 m)
                          (cairo_matrix_t-y0 m))))

    (def/public (get-transformation)
      (vector-immutable (get-initial-matrix)
                        origin-x origin-y
                        scale-x scale-y
                        rotation))

    (def/public (set-transformation [transformation-vector? v])
      (set-initial-matrix (vector-ref v 0))
      (set-origin (vector-ref v 1) (vector-ref v 2))
      (set-scale (vector-ref v 3) (vector-ref v 4))
      (set-rotation (vector-ref v 5)))

    (define/private (do-reset-matrix cr)
      (cairo_identity_matrix cr)
      (init-cr-matrix cr)
      (cairo_translate cr scroll-dx scroll-dy)
      (cairo_transform cr matrix)
      (cairo_translate cr origin-x origin-y)
      (cairo_scale cr scale-x scale-y)
      (cairo_rotate cr (- rotation)))
    
    (define/private (reset-matrix)
      (with-cr
       (void)
       cr
       (do-reset-matrix cr)))

    (inherit get-font-metrics-key)
    (define/public (cache-font-metrics-key)
      (get-font-metrics-key effective-scale-x effective-scale-y))

    (define/override (reset-cr cr)
      (set! contexts (make-vector (vector-length font-maps) #f))
      (set! desc-layoutss (make-vector (vector-length font-maps) #f))
      (do-reset-matrix cr)
      (when clipping-region
        (send clipping-region install-region cr scroll-dx scroll-dy
              (lambda (x) (align-x x)) (lambda (y) (align-y y)))))

    (define smoothing 'unsmoothed)

    (define/private (aligned? s)
      (not (eq? s 'smoothed)))

    (def/public (set-smoothing [(symbol-in unsmoothed smoothed aligned) s])
      (set! smoothing s))
    (def/public (get-smoothing)
      smoothing)
    (define/private (align-x/delta x delta)
      (if (aligned? smoothing)
          (/ (- (+ (floor (+ (* x effective-scale-x) effective-origin-x)) delta) 
                effective-origin-x) 
             effective-scale-x)
          x))
    (define/private (align-x x)
      (align-x/delta x x-align-delta))
    (define/private (align-y/delta y delta)
      (if (aligned? smoothing)
          (/ (- (+ (floor (+ (* y effective-scale-y) effective-origin-y)) delta) 
                effective-origin-y) 
             effective-scale-y)
          y))
    (define/private (align-y y)
      (align-y/delta y y-align-delta))

    ;; No alignment in any smoothing mode for text:
    (define/private (text-align-x/delta x delta) x)
    (define/private (text-align-y/delta y delta) y)

    (define current-smoothing #f)

    (define (set-font-antialias context smoothing)
      (let ([o (pango_cairo_context_get_font_options context)]
            [o2 (cairo_font_options_create)])
        (when o
          (cairo_font_options_copy o2 o))
        (cairo_font_options_set_antialias
         o2 
         (case smoothing
           [(default) (if (eq? (system-type) 'macosx)
                          CAIRO_ANTIALIAS_SUBPIXEL
                          CAIRO_ANTIALIAS_DEFAULT)]
           [(unsmoothed) CAIRO_ANTIALIAS_NONE]
           [(partly-smoothed) CAIRO_ANTIALIAS_GRAY]
           [(smoothed) CAIRO_ANTIALIAS_SUBPIXEL]))
        (pango_cairo_context_set_font_options context o2)
        (cairo_font_options_destroy o2)))

    (define alpha 1.0)
    (def/public (get-alpha) alpha)
    (def/public (set-alpha [(real-in 0.0 1.0) n])
      (set! alpha n))

    (define/public (do-set-pen! p)
      (set! pen-stipple-s #f)
      (let ([o pen])
        (send p adjust-lock 1)
        (set! pen p)
        (send o adjust-lock -1)))

    (define/public (set-pen . args)
      (case-args
       args
       [([pen% p]) (do-set-pen! p) (reset-align!)]
       [([(make-alts string? color%) col]
         [pen-width? width]
         [pen-style-symbol? style])
        (do-set-pen! (send the-pen-list find-or-create-pen col width style))
        (reset-align!)]
       (method-name 'dc<%> 'set-pen)))

    (define/public (get-pen) pen)

    (define/private (pen-draws?)
      (not (eq? (send pen get-style) 'transparent)))

    (define/public (do-set-brush! b)
      (set! brush-stipple-s #f)
      (let ([o brush])
        (send b adjust-lock 1)
        (set! brush b)
        (send o adjust-lock -1)))

    (define/public (set-brush . args)
      (case-args
       args
       [([brush% b]) (do-set-brush! b)]
       [([(make-alts string? color%) col]
         [brush-style-symbol? style])
        (do-set-brush! (send the-brush-list find-or-create-brush col style))]
       (method-name 'dc<%> 'set-brush)))

    (define/public (get-brush) brush)

    (define/private (brush-draws?)
      (not (eq? (send brush get-style) 'transparent)))

    (def/public (set-text-foreground [color% c])
      (set! text-fg (copy-color c)))
    (def/public (set-text-background [color% c])
      (set! text-bg (copy-color c)))
    (def/public (set-background [color% c])
      (set! pen-stipple-s #f)
      (set! brush-stipple-s #f)
      (set! bg (copy-color c)))

    (def/public (get-text-foreground) text-fg)
    (def/public (get-text-background) text-bg)
    (def/public (get-background) bg)

    (define/override (get-size)
      (check-ok 'get-size)
      (super get-size))

    (def/public (suspend-flush) (void))
    (def/public (resume-flush) (void))
    (def/public (flush) (void))

    (def/public (set-text-mode [(symbol-in solid transparent) mode])
      (set! text-mode mode))
    (def/public (get-text-mode) text-mode)

    (def/public (try-color [color% c] [color% dest])
      (check-ok 'try-color)
      (if (collapse-bitmap-b&w?)
          (let ([v (if (= 255
                          (color-red c)
                          (color-green c) 
                          (color-blue c))
                       255
                       0)])
            (send dest set v v v))
          (send dest set (color-red c) (color-green c) (color-blue c))))

    (define clipping-region #f)

    (def/public (get-clipping-region)
      clipping-region)
    (def/public (set-clipping-region [(make-or-false region%) r])
      (do-set-clipping-region r))
    (define/private (do-set-clipping-region r)
      (with-cr
       (void)
       cr
       (when clipping-region
         (send clipping-region lock-region -1))
       (set! clipping-region r)
       (reset-clip cr)
       (when clipping-region
         (send clipping-region lock-region 1)
         (send clipping-region install-region cr scroll-dx scroll-dy
               (lambda (x) (align-x x)) (lambda (y) (align-y y))))))

    (define/public (get-clipping-matrix)
      (let* ([cm (make-cairo_matrix_t (cairo_matrix_t-xx matrix)
                                      (cairo_matrix_t-yx matrix)
                                      (cairo_matrix_t-xy matrix)
                                      (cairo_matrix_t-yy matrix)
                                      (cairo_matrix_t-x0 matrix)
                                      (cairo_matrix_t-y0 matrix))])
        (cairo_matrix_translate cm origin-x origin-y)
        (cairo_matrix_scale cm scale-x scale-y)
        (cairo_matrix_rotate cm (- rotation))
        (vector (cairo_matrix_t-xx cm)
                (cairo_matrix_t-yx cm)
                (cairo_matrix_t-xy cm)
                (cairo_matrix_t-yy cm)
                (cairo_matrix_t-x0 cm)
                (cairo_matrix_t-y0 cm))))

    (def/public (set-clipping-rect [real? x] 
                                   [real? y] 
                                   [nonnegative-real? w]
                                   [nonnegative-real? h])
      (let ([r (make-object region% this)])
        (send r set-rectangle x y w h)
        (do-set-clipping-region r)))

    (define/private (check-ok who)
      (unless (ok?)
        (raise-mismatch-error (method-name 'dc<%> who) "drawing context is not ok: " this)))

    (define/public (clear)
      (with-cr
       (check-ok 'erase)
       cr
       (install-color cr bg 1.0)
       (cairo_paint cr)))

    (define/override (erase)
      (with-cr
       (check-ok 'erase)
       cr
       (cairo_set_operator cr CAIRO_OPERATOR_CLEAR)
       (cairo_set_source_rgba cr 1.0 1.0 1.0 1.0)
       (cairo_paint cr)
       (cairo_set_operator cr CAIRO_OPERATOR_OVER)))

    (def/public (copy [real? x] [real? y] [nonnegative-real? w] [nonnegative-real? h]
                      [real? x2] [real? y2])
      (with-cr
       (check-ok 'copy)
       cr
       (cairo_set_source_surface cr
                                 (cairo_get_target cr)
                                 (- x2 x) (- y2 y))
       (cairo_set_operator cr CAIRO_OPERATOR_SOURCE)
       (cairo_new_path cr)
       (cairo_rectangle cr x2 y2 w h)
       (cairo_fill cr)
       (cairo_set_operator cr CAIRO_OPERATOR_OVER)))

    (define/private (make-pattern-surface cr col draw)
      (let* ([s (cairo_surface_create_similar (cairo_get_target cr)
                                              CAIRO_CONTENT_COLOR_ALPHA
                                              12 12)]
             [cr2 (cairo_create s)])
        (install-color cr2 col alpha)
        (cairo_set_line_width cr2 1)
        (cairo_set_line_cap cr CAIRO_LINE_CAP_ROUND)
        (cairo_set_antialias cr2 (case (dc-adjust-smoothing smoothing)
                                   [(unsmoothed) CAIRO_ANTIALIAS_NONE]
                                   [else CAIRO_ANTIALIAS_GRAY]))
        (draw cr2)
        (cairo_stroke cr2)
        (cairo_destroy cr2)
        (let* ([p (cairo_pattern_create_for_surface s)])
          (cairo_surface_destroy s)
          (cairo_pattern_set_extend p CAIRO_EXTEND_REPEAT)
          (cairo_set_source cr p)
          (cairo_pattern_destroy p))))

    ;; Stroke, fill, and flush the current path
    (define/private (draw cr brush? pen?)
      (define (install-stipple st col mode get put)
        (let ([s (cond
                  [(get) => (lambda (s) s)]
                  [(and (not (send st is-color?))
                        (eq? mode 'solid)
                        (and (= 0 (color-red col))
                             (= 0 (color-green col))
                             (= 0 (color-blue col))))
                   (put (send st get-cairo-surface))]
                  [(collapse-bitmap-b&w?)
                   (put (send (bitmap-to-b&w-bitmap 
                               st 0 0 
                               (send st get-width) (send st get-height) mode col
                               #f)
                              get-cairo-surface))]
                  [(and (send st is-color?)
                        (= alpha 1.0))
                   (put (send st get-cairo-surface))]
                  [else
                   (put (send (bitmap-to-argb-bitmap 
                               st 0 0 
                               (send st get-width) (send st get-height) 
                               0 0 mode col alpha #f)
                              get-cairo-surface))])])
          (let* ([p (cairo_pattern_create_for_surface s)])
            (cairo_pattern_set_extend p CAIRO_EXTEND_REPEAT)
            (cairo_set_source cr p)
            (cairo_pattern_destroy p))))
      (cairo_set_antialias cr (case (dc-adjust-smoothing smoothing)
                                [(unsmoothed) CAIRO_ANTIALIAS_NONE]
                                [else CAIRO_ANTIALIAS_GRAY]))
      (when brush?
        (let ([s (send brush get-style)])
          (unless (eq? 'transparent s)
            (let ([st (send brush get-stipple)]
                  [col (send brush get-color)])
              (if st
                  (install-stipple st col s 
                                   (lambda () brush-stipple-s)
                                   (lambda (v) (set! brush-stipple-s v) v))
                  (let ([horiz (lambda (cr2)
                                 (cairo_move_to cr2 0 3.5)
                                 (cairo_line_to cr2 12 3.5)
                                 (cairo_move_to cr2 0 7.5)
                                 (cairo_line_to cr2 12 7.5)
                                 (cairo_move_to cr2 0 11.5)
                                 (cairo_line_to cr2 12 11.5))]
                        [vert (lambda (cr2)
                                (cairo_move_to cr2 3.5 0)
                                (cairo_line_to cr2 3.5 12)
                                (cairo_move_to cr2 7.5 0)
                                (cairo_line_to cr2 7.5 12)
                                (cairo_move_to cr2 11.5 0)
                                (cairo_line_to cr2 11.5 12))]
                        [bdiag (lambda (cr2)
                                 (for ([i (in-range -2 3)])
                                   (let ([y (* i 6)])
                                     (cairo_move_to cr2 -1 (+ -1 y))
                                     (cairo_line_to cr2 13 (+ 13 y)))))]
                        [fdiag (lambda (cr2)
                                 (for ([i (in-range -2 3)])
                                   (let ([y (* i 6)])
                                     (cairo_move_to cr2 13 (+ -1 y))
                                     (cairo_line_to cr2 -1 (+ 13 y)))))])
                                 
                    (case s
                      [(horizontal-hatch)
                       (make-pattern-surface
                        cr col
                        horiz)]
                      [(vertical-hatch)
                       (make-pattern-surface
                        cr col
                        vert)]
                      [(cross-hatch)
                       (make-pattern-surface
                        cr col
                        (lambda (cr) (horiz cr) (vert cr)))]
                      [(bdiagonal-hatch)
                       (make-pattern-surface
                        cr col
                        bdiag)]
                      [(fdiagonal-hatch)
                       (make-pattern-surface
                        cr col
                        fdiag)]
                      [(crossdiag-hatch)
                       (make-pattern-surface
                        cr col
                        (lambda (cr) (bdiag cr) (fdiag cr)))]
                      [else
                       (install-color cr 
                                      (if (eq? s 'hilite) hilite-color col)
                                      (if (eq? s 'hilite) hilite-alpha alpha))]))))
            (cairo_fill_preserve cr))))
      (when pen?
        (let ([s (send pen get-style)])
          (unless (eq? 'transparent s)
            (let ([st (send pen get-stipple)]
                  [col (send pen get-color)])
              (if st
                  (install-stipple st col s
                                   (lambda () pen-stipple-s)
                                   (lambda (v) (set! pen-stipple-s v) v))
                  (install-color cr 
                                 (if (eq? s 'hilite) hilite-color col)
                                 (if (eq? s 'hilite) hilite-alpha alpha))))
            (cairo_set_line_width cr (let* ([v (send pen get-width)]
                                            [v (if (aligned? smoothing)
                                                   (/ (floor (* effective-scale-x v)) effective-scale-x)
                                                   v)])
                                       (if (zero? v)
                                           1
                                           v)))
            (unless (or (eq? s 'solid)
                        (eq? s 'xor))
              (cairo_set_dash cr
                              (let ([vec (cond
                                          [(eq? s 'long-dash)
                                           #(4.0 2.0)]
                                          [(eq? s 'short-dash)
                                           #(2.0 2.0)]
                                          [(eq? s 'dot)
                                           #(1.0 2.0)]
                                          [(eq? s 'dot-dash)
                                           #(1.0 2.0 4.0 2.0)]
                                          [else
                                           #()])])
                                (let ([w (send pen get-width)])
                                  (if (w . > . 1.0)
                                      (list->vector
                                       (for/list ([a (in-vector vec)])
                                         (* a w)))
                                      vec)))
                              (cond
                               [(eq? s 'long-dash) 2]
                               [(eq? s 'short-dash) 2]
                               [(eq? s 'dot) 2]
                               [(eq? s 'dot-dash) 4]
                               [else 0])))
            (cairo_set_line_cap cr
                                (case (if ((send pen get-width) . <= . 1.0)
                                          'round
                                          (send pen get-cap))
                                  [(butt) CAIRO_LINE_CAP_BUTT]
                                  [(round) CAIRO_LINE_CAP_ROUND]
                                  [(projecting) CAIRO_LINE_CAP_SQUARE]))
            (cairo_set_line_join cr
                                 (case (send pen get-join)
                                   [(miter) CAIRO_LINE_JOIN_MITER]
                                   [(round) CAIRO_LINE_JOIN_ROUND]
                                   [(bevel) CAIRO_LINE_JOIN_BEVEL]))
            (cairo_stroke cr)
            (unless (or (eq? s 'solid) (eq? s 'xor))
              (cairo_set_dash cr #() 0)))))
      (flush-cr))
    
    (define/private (do-draw-arc who 
                                 x y
                                 width height
                                 start-radians end-radians)
      (with-cr 
       (check-ok who)
       cr
       (let ([draw-one (lambda (align-x align-y brush? pen? d)
                         (let* ([orig-x x]
                                [orig-y y]
                                [x (align-x x)]
                                [y (align-y y)]
                                [width (- (align-x (+ orig-x width)) x)]
                                [width (if (width . >= . d) (- width d) width)]
                                [height (- (align-y (+ orig-y height)) y)]
                                [height (if (height . >= . d) (- height d) height)]
                                [radius-x (/ width 2)]
                                [radius-y (/ height 2)]
                                [center-x (+ x radius-x)]
                                [center-y (+ y radius-y)])
                           ;; Cairo arcs go clockwise, while the dc goes counterclockwise
                           (when (and (positive? radius-x)
                                      (positive? radius-y))
                             (cairo_new_path cr)
                             (cairo_save cr)
                             (cairo_translate cr center-x center-y)
                             (cairo_scale cr radius-x radius-y)
                             (when brush?
                               (cairo_move_to cr 0 0))
                             (cairo_arc_negative cr 0 0 1
                                                 (- start-radians)
                                                 (- end-radians))
                             (when brush? 
                               (cairo_close_path cr))
                             (cairo_restore cr)
                             (draw cr brush? pen?))))])
         (when (brush-draws?)
           (draw-one (lambda (x) x) (lambda (y) y) #t #f 0.0))
         (when (pen-draws?)
           (draw-one (lambda (x) (align-x x)) (lambda (y) (align-y y)) #f #t 1.0)))))

    (def/public (draw-arc [real? x] [real? y] [nonnegative-real? width] [nonnegative-real? height]
                          [real? start-radians] [real? end-radians])
      (do-draw-arc 'draw-arc x y width height start-radians end-radians))

    (def/public (draw-ellipse [real? x] [real? y] [nonnegative-real? width] [nonnegative-real? height])
      (do-draw-arc 'draw-ellipse x y width height 0 2pi))

    (def/public (draw-line [real? x1] [real? y1] [real? x2] [real? y2])
      (let ([dot (if (and (= x1 x2) (= y1 y2))
                     0.1
                     0)])
        (with-cr
         (check-ok 'draw-line)
         cr
         (cairo_new_path cr)
         (cairo_move_to cr (align-x x1) (align-y y1))
         (cairo_line_to cr (+ (align-x x2) dot) (+ (align-y y2) dot))
         (draw cr #f #t))))
    
    (def/public (draw-point [real? x] [real? y])
      (with-cr
       (check-ok 'draw-point)
       cr
       (cairo_new_path cr)
       (let ([x (align-x x)]
             [y (align-y y)])
         (cairo_move_to cr x y)
         (cairo_line_to cr (+ 0.1 x) (+ 0.1 y))
       (draw cr #f #t))))

    (def/public (draw-lines [(make-alts (make-list point%) list-of-pair-of-real?) pts]
                            [real? [x 0.0]] [real? [y 0.0]])
      (do-draw-lines 'draw-lines pts x y #f))

    (def/public (draw-polygon [(make-alts (make-list point%) list-of-pair-of-real?) pts]
                              [real? [x 0.0]] [real? [y 0.0]]
                              [(symbol-in odd-even winding) [fill-style 'odd-even]])
      (do-draw-lines 'draw-polygon pts x y fill-style))

    (define/public (do-draw-lines who pts x y fill-style)
      (if (or (null? pts)
              (null? (cdr pts)))
          (check-ok who)
          (with-cr
           (check-ok who)
           cr
           (cairo_new_path cr)
           (if (pair? (car pts))
               (cairo_move_to cr (align-x (+ x (caar pts))) (align-y (+ y (cdar pts))))
               (cairo_move_to cr (align-x (+ x (point-x (car pts)))) (align-y (+ y (point-y (car pts))))))
           (for ([p (in-list (cdr pts))])
             (if (pair? p)
                 (cairo_line_to cr (align-x (+ x (car p))) (align-y (+ y (cdr p))))
                 (cairo_line_to cr (align-x (+ x (point-x p))) (align-y (+ y (point-y p))))))
           (when fill-style
             (cairo_close_path cr)
             (cairo_set_fill_rule cr (if (eq? fill-style 'winding)
                                         CAIRO_FILL_RULE_WINDING
                                         CAIRO_FILL_RULE_EVEN_ODD)))
           (draw cr fill-style #t))))
    
    (def/public (draw-rectangle [real? x] [real? y] [nonnegative-real? width] [nonnegative-real? height])
      (with-cr
       (check-ok 'draw-rectangle)
       cr
       ;; have to do pen separate from brush for 
       ;; both alignment and height/width adjustment
       (let ([ax (align-x x)]
             [ay (align-y y)])
         (cairo_new_path cr)
         (cairo_rectangle cr x y width height)
         (draw cr #t #f)
         (cairo_new_path cr)
         (cairo_rectangle cr ax ay
                          (- (align-x (+ x (sub1 width))) ax)
                          (- (align-y (+ y (sub1 height))) ay))
         (draw cr #f #t))))

    (def/public (draw-rounded-rectangle [real? x] [real? y] [nonnegative-real? width] [nonnegative-real? height]
                                        [real? [radius -0.25]])
      (with-cr
       (check-ok 'draw-rounded-rectangle)
       cr
       ;; have to do pen separate from brush for 
       ;; both alignment and height/width adjustment
       (let ([rounded-rect
              (lambda (x y w h align-x align-y)
                (let ([p (new dc-path%)])
                  (send p rounded-rectangle x y w h radius)
                  (cairo_new_path cr)
                  (send p do-path cr align-x align-y)))])
         (when (brush-draws?)
           (rounded-rect x y width height (lambda (x) x) (lambda (y) y))
           (draw cr #t #f))
         (when (pen-draws?)
           (rounded-rect x y (sub1 width) (sub1 height)
                         (lambda (x) (align-x x)) (lambda (y) (align-y y)))
           (draw cr #f #t)))))

    (def/public (draw-spline [real? x1] [real? y1] [real? x2] [real? y2] [real? x3] [real? y3])
      (with-cr
       (check-ok 'draw-spline)
       cr
       (cairo_new_path cr)
       (cairo_move_to cr (align-x x1) (align-y y1))
       (let ([x21 (/ (+ x1 x2) 2)]
             [y21 (/ (+ y1 y2) 2)])
         (cairo_line_to cr (align-x x21) (align-y y21))
         (let* ([x22 (/ (+ x2 x3) 2)]
                [y22 (/ (+ y2 y3) 2)]
                [xm1 (/ (+ x21 x2) 2)]
                [ym1 (/ (+ y21 y2) 2)]
                [xm2 (/ (+ x2 x22) 2)]
                [ym2 (/ (+ y2 y22) 2)])
           (cairo_curve_to cr 
                           (align-x xm1) (align-y ym1)
                           (align-x xm2) (align-y ym2)
                           (align-x x22) (align-y y22)))
         (cairo_line_to cr (align-x x3) (align-x y3)))
       (draw cr #f #t)))

    (def/public (draw-path [dc-path% path]
                           [real? [dx 0]]
                           [real? [dy 0]]
                           [(symbol-in odd-even winding) [fill-style 'odd-even]])
      (with-cr
       (check-ok 'draw-path)
       cr
       (cairo_save cr)
       (cairo_set_fill_rule cr (if (eq? fill-style 'winding)
                                   CAIRO_FILL_RULE_WINDING
                                   CAIRO_FILL_RULE_EVEN_ODD))
       (cairo_new_path cr)
       (cairo_translate cr dx dy)
       (if (aligned? smoothing)
           (begin
             (when (brush-draws?)
               (send path do-path cr (lambda (x) x) (lambda (y) y))
               (draw cr #t #f))
             (cairo_new_path cr)
             (when (pen-draws?)
               (send path do-path cr (lambda (x) (align-x x)) (lambda (y) (align-y y)))
               (draw cr #f #t)))
           (begin
             (send path do-path cr (lambda (x) x) (lambda (y) y))
             (draw cr #t #t)))
       (cairo_restore cr)))

    (def/public (draw-text [string? s] [real? x] [real? y]
                           [any? [combine? #f]]
                           [exact-nonnegative-integer? [offset 0]]
                           [real? [angle 0.0]])
      (with-cr
       (check-ok 'draw-text)
       cr
       (do-text cr #t s x y font combine? offset angle)
       (flush-cr)))

    (define size-cache (make-weak-hasheq))

    (define/private (get-size-cache desc)
      (or (hash-ref size-cache desc #f)
          (let ([h (make-hasheq)])
            (hash-set! size-cache desc h)
            h)))

    (def/public (get-text-extent [string? s] 
                                 [(make-or-false font%) [use-font font]]
                                 [any? [combine? #f]]
                                 [exact-nonnegative-integer? [offset 0]])
      (check-ok 'get-text-extent)
      (let ([use-font (or use-font font)])
        ;; Try to used cached size info, first:
        (let-values ([(w h d a)
                      (if (or combine?
                              (not (= 1.0 effective-scale-x))
                              (not (= 1.0 effective-scale-y)))
                          (values #f #f #f #f)
                          (let ([cache (get-size-cache (get-pango use-font))])
                            (if (= offset (string-length s))
                                ;; empty string, so measure space character for height
                                (let ([v (hash-ref cache (char->integer #\space) #f)])
                                  (if v
                                      (values 0 (vector-ref v 1) (vector-ref v 2) (vector-ref v 3))
                                      (values #f #f #f #f)))
                                ;; iterate through string
                                (let loop ([i offset] [w 0.0] [h 0.0] [d 0.0] [a 0.0])
                                  (if (= i (string-length s))
                                      (values w h d a)
                                      (let ([ch (string-ref s i)])
                                        (let ([v (hash-ref cache (char->integer ch) #f)])
                                          (if v
                                              (loop (add1 i)
                                                    (+ w (vector-ref v 0)) 
                                                    (max h (vector-ref v 1))
                                                    (max d (vector-ref v 2))
                                                    (max a (vector-ref v 3)))
                                              (values #f #f #f #f)))))))))])
          (if w
              (values w h d a)
              (with-cr
               (values 1.0 1.0 0.0 0.0)
               cr
               (do-text cr #f s 0 0 use-font combine? offset 0.0))))))

    (define/private (do-text cr draw? s x y font combine? offset angle)
      (let* ([s (if (zero? offset) 
                    s 
                    (substring s offset))]
             [blank? (string=? s "")]
             [s (if (and (not draw?) blank?) " " s)]
             [rotate? (and draw? (not (zero? angle)))]
             [smoothing-index (case (dc-adjust-smoothing (send font get-smoothing))
                                [(default) 0]
                                [(unsmoothed) 1]
                                [(partly-smoothed) 2]
                                [(smoothed) 3])]
             [context (or (vector-ref contexts smoothing-index)
                          (let ([c (pango_font_map_create_context
                                    (let ([fm (vector-ref font-maps smoothing-index)])
                                      (or fm
                                          (let ([fm (pango_cairo_font_map_new)])
                                            (vector-set! font-maps smoothing-index fm)
                                            fm))))])
                            (pango_cairo_update_context cr c)
                            (vector-set! contexts smoothing-index c)
                            (set-font-antialias c (dc-adjust-smoothing (send font get-smoothing)))
                            c))])
        (when draw?
          (when (eq? text-mode 'solid)
            (unless rotate?
              (let-values ([(w h d a) (do-text cr #f s 0 0 font combine? 0 0.0)])
                (install-color cr text-bg alpha)
                (cairo_new_path cr)
                (cairo_rectangle cr x y w h)
                (cairo_fill cr))))
          (cairo_new_path cr) ; important for underline mode
          (install-color cr text-fg alpha))
        (when rotate?
          (cairo_save cr)
          (cairo_translate cr x y)
          (cairo_rotate cr (- angle)))
        (let ([desc (get-pango font)]
              [attrs (send font get-pango-attrs)]
              [integral round]
              [x (if rotate? 0.0 (exact->inexact x))]
              [y (if rotate? 0.0 (exact->inexact y))])
          ;; We have two ways to draw text:
          ;;  - If `combine?' (to enable kerning etc.), then we create a Pango layout
          ;;    and draw it. This is the slow but pretty way (bt not used for editors,
          ;;    where the text needs to draw the same if it's drawn all together or
          ;;    in pieces).
          ;;  - If not `combine' or if combining isn't supported (e.g., because the scale
          ;;    is too small, so that it would look bad), then we draw character by character.
          (if (and combine?
                   (can-combine-text? (* effective-scale-y (send font get-point-size))))
              ;; This is combine mode. It has to be a little complicated, after all,
              ;; because we may need to implement font substitution ourselves, which
              ;; breaks the string into multiple layouts.
              (let loop ([s s] [w 0.0] [h 0.0] [d 0.0] [a 0.0])
                (cond
                 [(not s)
                  (when rotate? (cairo_restore cr))
                  (values w h d a)]
                 [else
                  (let ([layout (pango_layout_new context)]
                        [next-s #f])
                    (pango_layout_set_font_description layout desc)
                    (when attrs (pango_layout_set_attributes layout attrs))
                    (pango_layout_set_text layout s)
                    (let ([next-s
                           (if (or (not substitute-fonts?)
                                   (zero? (pango_layout_get_unknown_glyphs_count layout)))
                               #f
                               ;; look for the first character in the string without a glyph
                               (let ([ok-count
                                      (let ([len (string-length s)])
                                        (let loop ([lo 0] [hi (sub1 len)] [i (quotient len 2)])
                                          (cond
                                           [(= lo hi) lo]
                                           [else
                                            (pango_layout_set_text layout (substring s lo i))
                                            (if (zero? (pango_layout_get_unknown_glyphs_count layout))
                                                ;; ok so far, so look higher
                                                (if (= i lo)
                                                    lo
                                                    (loop i hi (+ i (quotient (- hi i) 2))))
                                                ;; still not ok; look lower
                                                (loop lo i (+ lo (quotient (- i lo) 2))))])))])
                                 (pango_layout_set_text layout (substring s 0 (max 1 ok-count)))
                                 (when (zero? ok-count)
                                   ;; find a face that works for the long character:
                                   (install-alternate-face (string-ref s 0) layout font desc attrs context))
                                 (substring s (max 1 ok-count))))])
                      (let ([logical (make-PangoRectangle 0 0 0 0)])
                        (pango_layout_get_extents layout #f logical)
                        (when draw?
                          (let ([bl (/ (pango_layout_get_baseline layout) (exact->inexact PANGO_SCALE))])
                            (pango_layout_get_extents layout #f logical)
                            (cairo_move_to cr (text-align-x/delta (+ x w) 0) (text-align-y/delta (+ y bl) 0))
                            ;; Draw the text:
                            (pango_cairo_show_layout_line cr (pango_layout_get_line_readonly layout 0))))
                        (cond
                         [(and draw? (not next-s))
                          (g_object_unref layout)
                          (when rotate? (cairo_restore cr))]
                         [else
                          (let ([nw (if blank?
                                        0.0
                                        (integral (/ (PangoRectangle-width logical) (exact->inexact PANGO_SCALE))))]
                                [nh (/ (PangoRectangle-height logical) (exact->inexact PANGO_SCALE))]
                                [nd (/ (- (PangoRectangle-height logical)
                                          (pango_layout_get_baseline layout))
                                       (exact->inexact PANGO_SCALE))]
                                [na 0.0])
                            (loop next-s (+ w nw) (max h nh) (max d nd) (max a na)))]))))]))
              ;; This is character-by-character mode. It uses a cached per-character+font layout
              ;;  object.
              (let ([cache (if (or combine?
                                   (not (fl= 1.0 effective-scale-x))
                                   (not (fl= 1.0 effective-scale-y)))
                               #f
                               (get-size-cache desc))]
                    [layouts (let ([attr-layouts (or (hash-ref (let ([t (vector-ref desc-layoutss smoothing-index)])
                                                                 (or t
                                                                     (let ([t (make-weak-hasheq)])
                                                                       (vector-set! desc-layoutss smoothing-index t)
                                                                       t)))
                                                               desc 
                                                               #f)
                                                     (let ([layouts (make-hasheq)])
                                                       (hash-set! (vector-ref desc-layoutss smoothing-index) desc layouts)
                                                       layouts))])
                               (or (hash-ref attr-layouts attrs #f)
                                   (let ([layouts (make-hasheq)])
                                     (hash-set! attr-layouts attrs layouts)
                                     layouts)))]
                    [xform current-xform])
                ;; First, ensure that all layout records are ready:
                (for ([ch (in-string s)])
                  (let* ([layout-info
                          (or (hash-ref layouts (char->integer ch) #f)
                              (let ([layout (pango_layout_new context)])
                                (pango_layout_set_font_description layout desc)
                                (when attrs (pango_layout_set_attributes layout attrs))
                                (pango_layout_set_text layout (string ch))
                                (unless (or (not substitute-fonts?)
                                            (zero? (pango_layout_get_unknown_glyphs_count layout)))
                                  ;; No good glyph; look for an alternate face
                                  (install-alternate-face ch layout font desc attrs context))
                                ;; layout-info vector is (vector _layout _xform _run _font _glyphs)
                                (let ([layout-info (vector layout xform #f #f #f)])
                                  (extract-only-run layout layout-info)
                                  (hash-set! layouts (char->integer ch) layout-info)
                                  layout-info)))]
                         [layout (vector-ref layout-info 0)])
                    (unless (equal? xform (vector-ref layout-info 1))
                      (pango_cairo_update_layout cr layout)
                      (vector-set! layout-info 1 xform)
                      (extract-only-run layout layout-info))))
                ;; At this point, we have two options for dealing with the layouts.
                ;; If layouts all use the same font and a single glyph, then
                ;; build a glyph string with the right offsets and draw all the
                ;; characters at once. That's faster, but it only works if there
                ;; are no font substitions or other fancy glyph transformations.
                ;; We try the fast way, and bail out to the low way if it doesn't
                ;; work. Also, we don't bother with the fast way if there's just one
                ;; character or if we're just measuring text.
                (begin0
                 (unless (and
                          draw?
                          cache
                          (not attrs) ; fast path doesn't handle underline
                          ((string-length s) . > . 1)
                          (let ([len (string-length s)]
                                [first-v (hash-ref cache (char->integer (string-ref s 0)) #f)]
                                [pgi-size (ctype-sizeof _PangoGlyphInfo)])
                            ;; Check whether the fast way applies. The speed of this
                            ;; loop directly affects the responsiveness of the DrRacket
                            ;; editor.
                            (let ([glyph-infos (malloc len _PangoGlyphInfo 'raw)] ;; assuming atomic until `free' below
                                  [log-clusters (malloc len _int 'raw)]
                                  [first-font (vector-ref (hash-ref layouts (char->integer (string-ref s 0))) 3)]
                                  [first-ascent (and first-v (fl- (vector-ref first-v 1) (vector-ref first-v 2)))])
                              (and
                               (let loop ([i 0])
                                 (or (= i len)
                                     (let* ([ch (string-ref s i)]
                                            [chi (char->integer ch)]
                                            [layout-info (hash-ref layouts chi)]
                                            [font (vector-ref layout-info 3)]
                                            [glyphs (vector-ref layout-info 4)]
                                            [v (hash-ref cache chi #f)])
                                       (and font
                                            v
                                            ;; Need the same font for all glyphs for the fast path:
                                            (ptr-equal? first-font font)
                                            ;; The slow path uses a top-left corner, this fast
                                            ;; path uses a baseline, so only use the fast path
                                            ;; if those two are consistent:
                                            (fl= first-ascent (fl- (vector-ref v 1) (vector-ref v 2)))
                                            ;; Assume that the rect of the characters will pan out,
                                            ;; and start filling in the glyph-info array:
                                            (memcpy glyph-infos i glyphs 1 _PangoGlyphInfo)
                                            ;; Every glyph is is own cluster:
                                            (ptr-set! log-clusters _int i i)
                                            ;; Adjust width to be consistent with integral widths
                                            ;; used when drawing individual characters.
                                            ;; This is `set-PangoGlyphInfo-width!', but without
                                            ;; computing a 
                                            (ptr-set! glyph-infos _uint32 'abs (+ (* i pgi-size) 4) (vector-ref v 5))
                                            (loop (add1 i))))))
                               ;; If we get here, we can use the fast way:
                               (let ([glyph-string (make-PangoGlyphString len
                                                                          glyph-infos
                                                                          log-clusters)])
                                 ;; Move into position (based on the recorded Pango-units baseline)
                                 ;; and draw the glyphs
                                 (cairo_move_to cr 
                                                (text-align-x/delta x 0) 
                                                (text-align-y/delta (+ y (/ (vector-ref first-v 4) (->fl PANGO_SCALE))) 0))
                                 (pango_cairo_show_glyph_string cr first-font glyph-string)
                                 (free glyph-infos)
                                 (free log-clusters)
                                 #t)))))
                   ;; We use the slower, per-layout way:
                   (for/fold ([w 0.0][h 0.0][d 0.0][a 0.0])
                       ([ch (in-string s)])
                     (let ([layout (vector-ref (hash-ref layouts (char->integer ch)) 0)])
                       (let-values ([(lw lh ld la flh)
                                     (let ([v (and cache (hash-ref cache (char->integer ch) #f))])
                                       (if v
                                           ;; Used cached size:
                                           (values (vector-ref v 0)
                                                   (vector-ref v 1)
                                                   (vector-ref v 2)
                                                   (vector-ref v 3)
                                                   (vector-ref v 6))
                                           ;; Query and record size:
                                           (let ([logical (make-PangoRectangle 0 0 0 0)])
                                             (pango_layout_get_extents layout #f logical)
                                             (let ([baseline (pango_layout_get_baseline layout)]
                                                   [orig-h (PangoRectangle-height logical)])
                                               ;; We keep integer width & height to pixel-align each individual character,
                                               ;; but we keep non-integral lh & ld to pixel-align the baseline.
                                               (let ([lw (integral (/ (PangoRectangle-width logical) 
                                                                      (exact->inexact PANGO_SCALE)))]
                                                     [flh (/ orig-h (exact->inexact PANGO_SCALE))]
                                                     [ld (/ (- orig-h baseline) (exact->inexact PANGO_SCALE))]
                                                     [la 0.0])
                                                 (let ([lh (ceiling flh)])
                                                   (when cache
                                                     (hash-set! cache (char->integer ch) 
                                                                (vector lw lh ld la 
                                                                        ;; baseline in Pango units; for fast path
                                                                        baseline
                                                                        ;; rounded width in Pango units; for fast path
                                                                        (inexact->exact
                                                                         (floor (* lw (->fl PANGO_SCALE))))
                                                                        ;; unrounded height, for slow-path alignment
                                                                        flh)))
                                                   (values lw lh ld la flh)))))))])
                         (when draw?
                           (cairo_move_to cr 
                                          (text-align-x/delta (+ x w) 0) 
                                          (let ([bl (- flh ld)])
                                            (text-align-y/delta (+ y bl) 0)))
                           ;; Here's the draw command, which uses most of the time in this mode:
                           (pango_cairo_show_layout_line cr (pango_layout_get_line_readonly layout 0)))
                         (values (if blank? 0.0 (+ w lw)) (max h lh) (max d ld) (max a la))))))
                 (when rotate? (cairo_restore cr))))))))

    (define/private (extract-only-run layout vec)
      (let* ([iter (pango_layout_get_iter layout)]
             [run (pango_layout_iter_get_run_readonly iter)]
             [done? (or (not (pango_layout_iter_next_run iter))
                        (and (not (pango_layout_iter_get_run_readonly iter))
                             (not (pango_layout_iter_next_run iter))))])
        (pango_layout_iter_free iter)
        (or (and run
                 done?
                 (= 1 (PangoGlyphString-num_glyphs (PangoGlyphItem-glyphs run)))
                 (begin
                   (vector-set! vec 2 run)
                   (vector-set! vec 3 (PangoItem-font (PangoGlyphItem-item run)))
                   (vector-set! vec 4 (PangoGlyphString-glyphs (PangoGlyphItem-glyphs run)))
                   #t))
            (begin
              (vector-set! vec 2 #f)
              (vector-set! vec 3 #f)
              (vector-set! vec 4 #f)))))
    
    (define/private (install-alternate-face ch layout font desc attrs context)
      (or
       (for/or ([face (in-list 
                       (let ([v (hash-ref substitute-mapping (char->integer ch) #f)])
                         (cond
                          [(string? v) 
                           ;; found previously
                           (list v)]
                          [v 
                           ;; failed to find previously
                           null]
                          [else
                           ;; Hack: prefer Lucida Grande
                           (cons "Lucida Grande" (get-face-list))])))])
         (let ([desc (get-pango (make-object font%
                                             (send font get-point-size)
                                             face
                                             (send font get-family)
                                             (send font get-style)
                                             (send font get-weight)
                                             (send font get-underlined)
                                             (send font get-smoothing)
                                             (send font get-size-in-pixels)))])
           (and desc
                (let ([attrs (send font get-pango-attrs)])
                  (pango_layout_set_font_description layout desc)
                  (when attrs (pango_layout_set_attributes layout attrs))
                  (and (zero? (pango_layout_get_unknown_glyphs_count layout))
                       (begin
                         (hash-set! substitute-mapping (char->integer ch) face)
                         #t))))))
       (begin
         (hash-set! substitute-mapping (char->integer ch) #t)
         ;; put old desc & attrs back
         (pango_layout_set_font_description layout desc)
         (when attrs (pango_layout_set_attributes layout attrs)))))
    
    (def/public (get-char-width)
      10.0)

    (def/public (start-doc [string? desc])
      (check-ok 'start-doc))
    (def/public (end-doc)
      (check-ok 'end-doc)
      (end-cr))
    (def/public (start-page)
      (check-ok 'start-page))
    (def/public (end-page)
      (with-cr (check-ok 'end-page) cr (cairo_show_page cr)))

    (def/public (draw-bitmap [bitmap% src]
                             [real? dest-x]
                             [real? dest-y]
                             [(symbol-in solid opaque xor) [style 'solid]]
                             [(make-or-false color%) [color black]]
                             [(make-or-false bitmap%) [mask #f]])
      (draw-bitmap-section/mask-offset 'draw-bitmap
                                       src 
                                       dest-x dest-y 
                                       0 0
                                       (send src get-width) (send src get-height)
                                       0 0
                                       style color mask))

    (def/public (draw-bitmap-section [bitmap% src]
                                     [real? dest-x]
                                     [real? dest-y]
                                     [real? src-x]
                                     [real? src-y]
                                     [real? src-w]
                                     [real? src-h]
                                     [(symbol-in solid opaque xor) [style 'solid]]
                                     [(make-or-false color%) [color black]]
                                     [(make-or-false bitmap%) [mask #f]])
      (draw-bitmap-section/mask-offset 'draw-bitmap-section
                                       src dest-x dest-y src-x src-y src-w src-h src-x src-y
                                       style color mask))

    (define/public (draw-bitmap-section/mask-offset who
                                                    src dest-x dest-y src-x src-y src-w src-h msrc-x msrc-y
                                                    style color mask)
      (check-ok who)
      (let-values ([(src src-x src-y)
                    (if (and (alpha . < . 1.0)
                             (send src is-color?))
                        ;; need a faded source
                        (let* ([alpha-mask (make-object bitmap% (floor src-w) (floor src-h))]
                               [adc (make-object -bitmap-dc% alpha-mask)])
                          (send adc set-alpha alpha)
                          (send adc set-brush "black" 'solid)
                          (send adc draw-rectangle 0 0 src-w src-h)
                          (send adc set-bitmap #f)
                          (let ([tmp-bm (bitmap-to-argb-bitmap src src-x src-y src-w src-h 0 0 
                                                               style black 1.0 alpha-mask)])
                            (values tmp-bm 0 0)))
                        ;; no change to source
                        (values src src-x src-y))]
                   [(clip-mask) (and mask 
                                     (not (can-mask-bitmap?))
                                     (let* ([bm-w (floor src-w)]
                                            [bm-h (floor src-h)]
                                            [bstr (make-bytes (* bm-w bm-h 4))])
                                       (send mask get-argb-pixels 
                                             (inexact->exact (floor msrc-x))
                                             (inexact->exact (floor msrc-y))
                                             bm-w
                                             bm-h
                                             bstr
                                             #t)
                                       bstr))]
                   [(mask) (if mask
                               (and (can-mask-bitmap?) mask)
                               #f)])
        (let ([black? (or (not color)
                          (and (= 0 (color-red color))
                               (= 0 (color-green color))
                               (= 0 (color-blue color))))])
          (cond
           [(and (collapse-bitmap-b&w?)
                 (or (send src is-color?)
                     (and mask
                          (send mask is-color?))))
            ;; Need to ensure that the result is still B&W
            (let* ([tmp-bm (bitmap-to-b&w-bitmap src src-x src-y src-w src-h style color mask)])
              (do-draw-bitmap-section tmp-bm dest-x dest-y 0 0 src-w src-h 0 0 'solid #f #t #f clip-mask))]
           [(and mask
                 (or (not black?)
                     (alpha . < . 1.0)))
            ;; mask plus color or alpha with a color bitmap
            (let ([tmp-bm (bitmap-to-argb-bitmap src src-x src-y src-w src-h 0 0 style color alpha #f)])
              (do-draw-bitmap-section tmp-bm dest-x dest-y 0 0 src-w src-h msrc-x msrc-y 'solid #f #t mask clip-mask))]
           [else
            ;; Normal combination...
            (do-draw-bitmap-section src dest-x dest-y src-x src-y src-w src-h msrc-x msrc-y
                                    style color black? mask clip-mask)]))))

    (define/public (do-draw-bitmap-section src dest-x dest-y src-x src-y src-w src-h msrc-x msrc-y 
                                           style color black? mask clip-mask)
      (with-cr
       (void)
       cr
       (when clip-mask
         ;; Implement mask by clipping, because masks are not supported by the
         ;; dc. We treat an alpha of more than 128 as opaque, and less than 128
         ;; as transparent.
         (cairo_save cr)
         (let ([bm-w (floor src-w)]
               [bm-h (floor src-h)])
           (cairo_new_path cr)
           (for ([j (in-range 0 bm-h)])
             (let ([start
                    (for/fold ([start #f]) ([i (in-range 0 bm-w)])
                      (let ([new-on? ((bytes-ref clip-mask (* 4 (+ (* bm-w j) i))) . > . 128)])
                        (cond
                         [(and new-on? start) start]
                         [new-on? i]
                         [start
                          (cairo_rectangle cr (+ start dest-x) (+ j dest-y) (- i start) 1)
                          #f]
                         [else #f])))])
               (when start
                 (cairo_rectangle cr (+ start dest-x) (+ j dest-y) (- bm-w start) 1))))
           (cairo_clip cr)))
       (let* ([color (or color black)]
              [a-dest-x (align-x/delta dest-x 0)]
              [a-dest-y (align-y/delta dest-y 0)]
              [a-dest-w (- (align-x/delta (+ dest-x src-w) 0) a-dest-x)]
              [a-dest-h (- (align-y/delta (+ dest-y src-h) 0) a-dest-y)]
              [a-src-x (floor src-x)]
              [a-src-y (floor src-y)]
              [a-msrc-x (floor msrc-x)]
              [a-msrc-y (floor msrc-y)]
              [stamp-pattern
               (lambda (src a-src-x a-src-y)
                 (let ([p (cairo_pattern_create_for_surface (send src get-cairo-alpha-surface))]
                       [m (make-cairo_matrix_t 0.0 0.0 0.0 0.0 0.0 0.0)])
                   (cairo_matrix_init_translate m (- a-src-x a-dest-x) (- a-src-y a-dest-y))
                   (cairo_pattern_set_matrix p m)
                   (cairo_mask cr p)
                   (cairo_pattern_destroy p)))])
         (cond
          [(or (send src is-color?)
               (and (not (eq? style 'opaque))
                    (= alpha 1.0)
                    black?))
           (let ([s (cairo_get_source cr)])
             (cairo_pattern_reference s)
             (cairo_set_source_surface cr 
                                       (send src get-cairo-surface)
                                       (- a-dest-x a-src-x)
                                       (- a-dest-y a-src-y))
             (if mask
                 (stamp-pattern mask a-msrc-x a-msrc-y)
                 (begin
                   (cairo_new_path cr)
                   (cairo_rectangle cr a-dest-x a-dest-y a-dest-w a-dest-h)
                   (cairo_fill cr)))
             (cairo_set_source cr s)
             (cairo_pattern_destroy s))]
          [else
           (when (eq? style 'opaque)
             (install-color cr bg alpha)
             (cairo_new_path cr)
             (cairo_rectangle cr a-dest-x a-dest-y a-dest-w a-dest-h)
             (cairo_fill cr))
           (install-color cr color alpha)
           (stamp-pattern src a-src-x a-src-y)])
         (when clip-mask
           (cairo_restore cr))
         (flush-cr))))

    (define/private (bitmap-to-b&w-bitmap src src-x src-y src-w src-h style color mask)
      (let* ([bm-w (inexact->exact (ceiling src-w))]
             [bm-h (inexact->exact (ceiling src-h))]
             [tmp-bm (make-object bitmap% bm-w bm-h #f #t)]
             [tmp-dc (make-object -bitmap-dc% tmp-bm)])
        (send tmp-dc set-background bg)
        (send tmp-dc draw-bitmap-section src 0 0 src-x src-y src-w src-h style color mask)
        (send tmp-dc set-bitmap #f)
        (let ([bstr (make-bytes (* bm-w bm-h 4))])
          (send tmp-bm get-argb-pixels 0 0 bm-w bm-h bstr)
          (for ([i (in-range 0 (bytes-length bstr) 4)])
            (bytes-set! bstr i (if (= (bytes-ref bstr i) 255)
                                   255
                                   0))
            (let ([v (if (and (= 255 (bytes-ref bstr (+ i 1)))
                              (= 255 (bytes-ref bstr (+ i 2)))
                              (= 255 (bytes-ref bstr (+ i 3))))
                         255
                         0)])
              (bytes-set! bstr (+ i 1) v)
              (bytes-set! bstr (+ i 2) v)
              (bytes-set! bstr (+ i 3) v)))
          (send tmp-bm set-argb-pixels 0 0 bm-w bm-h bstr)
          tmp-bm)))
    
    (define/private (bitmap-to-argb-bitmap src src-x src-y src-w src-h msrc-x msrc-y 
                                           style color alpha mask) 
      (let* ([bm-w (inexact->exact (ceiling src-w))]
             [bm-h (inexact->exact (ceiling src-h))]
             [tmp-bm (make-object bitmap% src-w src-h #f #t)]
             [tmp-dc (make-object -bitmap-dc% tmp-bm)])
        (send tmp-dc set-alpha alpha)
        (send tmp-dc set-background bg)
        (send tmp-dc draw-bitmap-section/mask-offset 'internal src 0 0 src-x src-y src-w src-h msrc-x msrc-y
              style color mask)
        (send tmp-dc set-bitmap #f)
        tmp-bm))

    (def/public (glyph-exists? [char? c])
      (with-cr
       #f
       cr
       (let ([desc (get-pango font)]
             [attrs (send font get-pango-attrs)]
             [context (or (for/or ([c (in-vector contexts)])
                            c)
                          (pango_cairo_create_context cr))])
         (let ([layout (pango_layout_new context)])
           (pango_layout_set_font_description layout desc)
           (pango_layout_set_text layout (string c))
           (pango_cairo_update_layout cr layout)
           (begin0
            (or (zero? (pango_layout_get_unknown_glyphs_count layout))
                (and substitute-fonts?
                     (install-alternate-face c layout font desc attrs context)
                     (zero? (pango_layout_get_unknown_glyphs_count layout))))
            (g_object_unref layout))))))

    (void))

  dc%)