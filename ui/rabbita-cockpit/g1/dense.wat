;; Row-major BF16 operands expanded to f32 once. Accumulate a whole row
;; before rounding the linear output to BF16 in the caller.
(module
  (import "model" "memory" (memory 1))
  (func (export "linear") (param $w i32) (param $bias i32) (param $x i32)
        (param $y i32) (param $cols i32) (param $rows i32)
    (local $r i32) (local $i i32) (local $acc v128) (local $s f32)
    (loop $row
      (local.set $acc (v128.const f32x4 0 0 0 0))
      (local.set $i (i32.const 0))
      (block $tail (loop $dot
        (br_if $tail (i32.gt_u (i32.add (local.get $i) (i32.const 16)) (local.get $cols)))
        (local.set $acc (f32x4.add (local.get $acc) (f32x4.mul
          (v128.load (i32.add (local.get $w) (local.get $i)))
          (v128.load (i32.add (local.get $x) (local.get $i))))))
        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $dot)))
      (local.set $s (f32.add (f32.add (f32x4.extract_lane 0 (local.get $acc)) (f32x4.extract_lane 1 (local.get $acc)))
                             (f32.add (f32x4.extract_lane 2 (local.get $acc)) (f32x4.extract_lane 3 (local.get $acc)))))
      (block $done (loop $rest
        (br_if $done (i32.ge_u (local.get $i) (local.get $cols)))
        (local.set $s (f32.add (local.get $s) (f32.mul
          (f32.load (i32.add (local.get $w) (local.get $i)))
          (f32.load (i32.add (local.get $x) (local.get $i))))))
        (local.set $i (i32.add (local.get $i) (i32.const 4))) (br $rest)))
      (f32.store (local.get $y) (f32.add (local.get $s) (f32.load (local.get $bias))))
      (local.set $w (i32.add (local.get $w) (local.get $cols)))
      (local.set $bias (i32.add (local.get $bias) (i32.const 4)))
      (local.set $y (i32.add (local.get $y) (i32.const 4)))
      (local.set $r (i32.add (local.get $r) (i32.const 1)))
      (br_if $row (i32.lt_u (local.get $r) (local.get $rows))))))
