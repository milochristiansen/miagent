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

@(test)
test_url_validation :: proc(t: ^testing.T) {
	valid := []string{
		"https://example.com",
		"http://localhost:8080/path?q=1#frag",
		"https://user:pass@example.com/a_(b)",
		"https://[::1]:3000/",
		"mailto:dev@example.com",
	}
	for url in valid do testing.expectf(t, md_url_valid(url), "expected %q to be valid", url)

	invalid := []string{
		"example.com",
		"just text with a dot.",
		"https://",
		"http://.com",
		"http://a..b",
		"http://example.com:",
		"http://example.com:abc",
		"mailto:no-at-sign",
		"https://a b",
		"[label](https://example.com)",
	}
	for url in invalid do testing.expectf(t, !md_url_valid(url), "expected %q to be invalid", url)
}

@(test)
test_inline_bare_urls :: proc(t: ^testing.T) {
	words := inline_words("See https://example.com/path.")
	defer md_words_destroy(words)
	if !testing.expect_value(t, len(words), 3) do return
	testing.expect_value(t, words[0].text, "See")
	testing.expect_value(t, words[0].style, Md_Style.Text)
	testing.expect_value(t, words[1].text, "https://example.com/path")
	testing.expect_value(t, words[1].style, Md_Style.Link)
	testing.expect_value(t, words[1].url, "https://example.com/path")
	testing.expect_value(t, words[1].tip, "")
	testing.expect_value(t, words[2].text, ".")

	// Balanced parentheses stay part of the URL; an unmatched closing one is
	// treated as surrounding punctuation.
	words2 := inline_words("(https://example.com/a_(b))")
	defer md_words_destroy(words2)
	if !testing.expect_value(t, len(words2), 3) do return
	testing.expect_value(t, words2[0].text, "(")
	testing.expect_value(t, words2[1].text, "https://example.com/a_(b)")
	testing.expect_value(t, words2[2].text, ")")

	// A dot in ordinary prose is not a URL.
	words3 := inline_words("version 1.2.3 and example.com are not links")
	defer md_words_destroy(words3)
	for word in words3 do testing.expect_value(t, word.style, Md_Style.Text)

	// Code spans and invalid schemes stay literal.
	words4 := inline_words("`https://example.com` then ftp://example.com")
	defer md_words_destroy(words4)
	testing.expect_value(t, words4[0].style, Md_Style.Code)
	testing.expect_value(t, words4[0].url, "")
	for word in words4 do testing.expect(t, word.style != .Link)
}

@(test)
test_inline_markdown_links :: proc(t: ^testing.T) {
	words := inline_words("Read [the docs](https://example.com/docs) now")
	defer md_words_destroy(words)
	if !testing.expect_value(t, len(words), 4) do return
	testing.expect_value(t, words[1].text, "the")
	testing.expect_value(t, words[1].style, Md_Style.Link)
	testing.expect_value(t, words[1].url, "https://example.com/docs")
	testing.expect_value(t, words[1].tip, "https://example.com/docs")
	testing.expect_value(t, words[2].text, "docs")
	testing.expect_value(t, words[2].url, "https://example.com/docs")
	testing.expect_value(t, words[3].text, "now")

	// Angle-bracket destinations and optional titles are supported.
	words2 := inline_words("[site](<https://example.com/a_(b)> \"title\")")
	defer md_words_destroy(words2)
	if !testing.expect_value(t, len(words2), 1) do return
	testing.expect_value(t, words2[0].text, "site")
	testing.expect_value(t, words2[0].url, "https://example.com/a_(b)")

	// Relative or malformed destinations are not rendered as links.
	words3 := inline_words("[label](not-a-url) [empty]()")
	defer md_words_destroy(words3)
	for word in words3 do testing.expect_value(t, word.url, "")
}

@(test)
test_inline_link_inside_bold :: proc(t: ^testing.T) {
	words := inline_words("**see https://example.com**")
	defer md_words_destroy(words)
	if !testing.expect_value(t, len(words), 2) do return
	testing.expect_value(t, words[0].text, "see")
	testing.expect_value(t, words[0].style, Md_Style.Bold)
	testing.expect_value(t, words[1].text, "https://example.com")
	testing.expect_value(t, words[1].style, Md_Style.Link)
}

@(test)
test_markdown_image_parsing :: proc(t: ^testing.T) {
	alt, src, end, ok := md_markdown_image_at("![diagram](images/pic.png)", 0)
	if !testing.expect(t, ok) do return
	testing.expect_value(t, alt, "diagram")
	testing.expect_value(t, src, "images/pic.png")
	testing.expect_value(t, end, len("![diagram](images/pic.png)"))

	_, src, _, ok = md_markdown_image_at("![x](<images/a b.png> \"title\")", 0)
	if !testing.expect(t, ok) do return
	testing.expect_value(t, src, "images/a b.png")

	_, src, _, ok = md_markdown_image_at("![x](file:///tmp/pic.png)", 0)
	testing.expect(t, ok)
	testing.expect_value(t, src, "file:///tmp/pic.png")

	_, src, _, ok = md_markdown_image_at("![x](https://example.com/pic.png)", 0)
	testing.expect(t, ok)
	testing.expect_value(t, src, "https://example.com/pic.png")

	_, _, _, ok = md_markdown_image_at("![x](data:image/png;base64,AAAA)", 0)
	testing.expect(t, ok)
	_, _, _, ok = md_markdown_image_at("![x](data:text/plain;base64,AAAA)", 0)
	testing.expect(t, !ok)
	_, _, _, ok = md_markdown_image_at("![x](javascript:alert(1))", 0)
	testing.expect(t, !ok)
	_, _, _, ok = md_markdown_image_at("![x](ftp://example.com/pic.png)", 0)
	testing.expect(t, !ok)
	_, _, _, ok = md_markdown_image_at("not an image [x](images/pic.png)", 0)
	testing.expect(t, !ok)
}

@(test)
test_markdown_image_inline_fallback :: proc(t: ^testing.T) {
	words := inline_words("see ![alt](images/pic.png) here")
	defer md_words_destroy(words)
	if !testing.expect_value(t, len(words), 3) do return
	testing.expect_value(t, words[0].text, "see")
	testing.expect_value(t, words[1].text, "alt")
	testing.expect_value(t, words[2].text, "here")
	for word in words do testing.expect_value(t, word.style, Md_Style.Text)
}

@(test)
test_image_source_support :: proc(t: ^testing.T) {
	supported := []string{
		"images/pic.png",
		"images/pic with space.png",
		"./images/pic.png",
		"/tmp/pic.png",
		"file:///tmp/pic.png",
		"https://example.com/pic.png",
		"data:image/png;base64,AAAA",
	}
	for src in supported do testing.expectf(t, image_source_supported(src), "expected %q to be supported", src)

	unsupported := []string{
		"",
		"https://example.com/pic with space.png",
		"javascript:alert(1)",
		"ftp://example.com/pic.png",
		"data:text/plain;base64,AAAA",
	}
	for src in unsupported do testing.expectf(t, !image_source_supported(src), "expected %q to be unsupported", src)
}

@(test)
test_image_fit_rect :: proc(t: ^testing.T) {
	r := image_fit_rect(200, 100, 100, 100, false)
	testing.expectf(t, r.w == 100 && r.h == 50, "got %.1fx%.1f", r.w, r.h)

	r = image_fit_rect(100, 200, 100, 100, false)
	testing.expectf(t, r.w == 50 && r.h == 100, "got %.1fx%.1f", r.w, r.h)

	// Small images stay at natural size in the transcript.
	r = image_fit_rect(40, 20, 100, 100, false)
	testing.expectf(t, r.w == 40 && r.h == 20, "got %.1fx%.1f", r.w, r.h)

	// The expanded viewer may scale up, but respects its cap.
	r = image_fit_rect(40, 20, 1000, 1000, true, 2.0)
	testing.expectf(t, r.w == 80 && r.h == 40, "got %.1fx%.1f", r.w, r.h)
}

@(test)
test_find_markdown_image :: proc(t: ^testing.T) {
	testing.expect_value(t, md_find_image("diagram: ![x](images/pic.png) done"), len("diagram: "))
	testing.expect_value(t, md_find_image("no image here"), -1)
	testing.expect_value(t, md_find_image("code `![x](images/pic.png)` only"), -1)
	testing.expect_value(t, md_find_image("![x](images/pic.png)"), 0)
}

@(test)
test_markdown_link_with_closing_paren :: proc(t: ^testing.T) {
	label, url, end, ok := md_markdown_link_at("[Example link](https://example.com)", 0)
	if !testing.expect(t, ok) do return
	testing.expect_value(t, label, "Example link")
	testing.expect_value(t, url, "https://example.com")
	testing.expect_value(t, end, len("[Example link](https://example.com)"))

	// An unmatched closing parenthesis around a bare URL is punctuation.
	words := inline_words("(https://example.com)")
	defer md_words_destroy(words)
	testing.expect_value(t, words[1].text, "https://example.com")
	testing.expect_value(t, words[1].url, "https://example.com")
}

@(test)
test_example_link_words :: proc(t: ^testing.T) {
	words := inline_words("[Example link](https://example.com)")
	defer md_words_destroy(words)
	for word, i in words {
		testing.expectf(t, word.url == "https://example.com", "word %d %q url=%q", i, word.text, word.url)
	}
}
