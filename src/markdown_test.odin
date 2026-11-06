package main

import "core:testing"

expect_cells :: proc(t: ^testing.T, got, want: []string) {
	if !testing.expect_value(t, len(got), len(want)) do return
	for cell, i in got {
		testing.expectf(t, cell == want[i], "cell %d: got %q, want %q", i, cell, want[i])
	}
}

@(test)
test_table_row_split :: proc(t: ^testing.T) {
	expect_cells(t, md_split_table_row("| A | B |"), []string{"A", "B"})
	expect_cells(t, md_split_table_row("A | B"), []string{"A", "B"})
	expect_cells(t, md_split_table_row("| A \\| B | C |"), []string{"A | B", "C"})
	expect_cells(t, md_split_table_row("| | x |"), []string{"", "x"})
	expect_cells(t, md_split_table_row("| `a | b` |"), []string{"`a", "b`"})
}

@(test)
test_table_delimiter_alignment :: proc(t: ^testing.T) {
	aligns, ok := md_table_delimiter("| :--- | :---: | ---: | --- |")
	if !testing.expect(t, ok) do return
	want := []Md_Align{.Left, .Center, .Right, .Left}
	if !testing.expect_value(t, len(aligns), len(want)) do return
	for align, i in aligns do testing.expect_value(t, align, want[i])

	_, ok = md_table_delimiter("| --- | nope |")
	testing.expect(t, !ok)
	_, ok = md_table_delimiter("--- | ---")
	testing.expect(t, ok)
	_, ok = md_table_delimiter("---")
	testing.expect(t, !ok)
}

@(test)
test_table_start_and_end :: proc(t: ^testing.T) {
	lines := []string{
		"Name | Value",
		"--- | ---",
		"alpha | 1",
		"",
		"after",
	}
	testing.expect(t, md_is_table_start(lines, 0))
	testing.expect(t, !md_ends_table(lines, 2))
	testing.expect(t, md_ends_table(lines, 3))
	testing.expect(t, !md_is_table_start([]string{"| A |", "---"}, 0))

	// Any non-blank line is still a row; another block marker ends the table.
	testing.expect(t, !md_ends_table([]string{"| A |", "---", "plain row"}, 2))
	testing.expect(t, md_ends_table([]string{"| A |", "---", "# heading"}, 2))
}
