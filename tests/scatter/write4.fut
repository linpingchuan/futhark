-- Test that write works for arrays of tuples.
-- ==
--
-- input {
--   [0]
--   [9]
--   [1,2,3]
--   [4,5,6]
-- }
-- output {
--   [9,2,3]
--   [9,5,6]
-- }

let main(indexes: [#k]i32,
         values: [#k]i32,
         array1: *[#n]i32,
         array2: *[#n]i32): ([n]i32, [n]i32) =
  unzip (scatter (zip array1 array2) indexes (zip values values))
