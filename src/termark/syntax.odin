// A compact syntax highlighter for the languages an agent commonly emits.
// It is not a full lexer; it covers comments, strings, numbers, keywords,
// function names, and operators with the same monokai terminal-256 palette
// chroma uses in the Go CLI.
package termark

import "core:strings"

syntax_keyword :: proc(l, word: string) -> bool {
	words: []string
	switch l {
	case "go":
		words = {"break", "case", "chan", "const", "continue", "default", "defer", "else",
			"fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
			"map", "package", "range", "return", "select", "struct", "switch", "type",
			"var", "true", "false", "nil"}
	case "python":
		words = {"and", "as", "assert", "async", "await", "break", "class", "continue",
			"def", "del", "elif", "else", "except", "False", "finally", "for", "from",
			"global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
			"or", "pass", "raise", "return", "True", "try", "while", "with", "yield"}
	case "json":
		words = {"true", "false", "null"}
	case "javascript":
		words = {"break", "case", "catch", "class", "const", "continue", "debugger",
			"default", "delete", "do", "else", "export", "extends", "finally", "for",
			"function", "if", "import", "in", "instanceof", "let", "new", "return",
			"super", "switch", "this", "throw", "try", "typeof", "var", "void", "while",
			"with", "yield", "async", "await", "true", "false", "null", "undefined"}
	case "typescript":
		words = {"break", "case", "catch", "class", "const", "continue", "debugger",
			"default", "delete", "do", "else", "export", "extends", "finally", "for",
			"function", "if", "import", "in", "instanceof", "let", "new", "return",
			"super", "switch", "this", "throw", "try", "typeof", "var", "void", "while",
			"with", "yield", "async", "await", "true", "false", "null", "undefined",
			"interface", "type", "enum", "public", "private", "protected", "static",
			"implements", "readonly", "declare"}
	case "rust":
		words = {"as", "break", "const", "continue", "crate", "else", "enum", "extern",
			"false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
			"move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
			"super", "trait", "true", "type", "unsafe", "use", "where", "while",
			"async", "await", "dyn"}
	case "c", "cpp":
		words = {"auto", "break", "case", "char", "const", "continue", "default", "do",
			"double", "else", "enum", "extern", "float", "for", "goto", "if", "int",
			"long", "register", "return", "short", "signed", "sizeof", "static",
			"struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
			"while", "class", "namespace", "template", "public", "private", "protected",
			"virtual", "bool", "true", "false", "nullptr"}
	case "bash", "sh", "shell":
		words = {"if", "then", "else", "elif", "fi", "for", "while", "do", "done",
			"case", "esac", "function", "in", "select", "until", "time", "true", "false"}
	case "sql":
		words = {"select", "from", "where", "insert", "update", "delete", "create",
			"table", "drop", "alter", "join", "left", "right", "inner", "outer", "on",
			"group", "by", "order", "having", "limit", "offset", "and", "or", "not",
			"null", "true", "false", "as", "into", "values", "set"}
	case "java":
		words = {"abstract", "assert", "boolean", "break", "byte", "case", "catch",
			"char", "class", "const", "continue", "default", "do", "double", "else",
			"enum", "extends", "final", "finally", "float", "for", "goto", "if",
			"implements", "import", "instanceof", "int", "interface", "long", "native",
			"new", "package", "private", "protected", "public", "return", "short",
			"static", "strictfp", "super", "switch", "synchronized", "this", "throw",
			"throws", "transient", "try", "void", "volatile", "while", "true", "false",
			"null"}
	case "yaml":
		words = {"true", "false", "null", "yes", "no", "on", "off"}
	case "toml":
		words = {"true", "false"}
	}
	for w in words do if w == word do return true
	return false
}

known_language :: proc(lang: string) -> bool {
	l := strings.to_lower(strings.trim_space(lang), context.temp_allocator)
	switch l {
	case "go", "python", "json", "javascript", "js", "typescript", "ts", "rust",
		"c", "cpp", "c++", "bash", "sh", "shell", "sql", "java", "yaml", "toml",
		"diff", "patch", "html", "xml", "css", "ruby", "perl", "lua":
		return true
	}
	return false
}

is_ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

syntax_comment_start :: proc(l: string, line: string, i: int) -> int {
	switch l {
	case "python", "bash", "sh", "shell", "yaml", "toml", "ruby", "perl":
		if line[i] == '#' do return i
	case "sql", "lua":
		if i + 1 < len(line) && line[i] == '-' && line[i + 1] == '-' do return i
	case "html", "xml":
		if i + 3 < len(line) && line[i:i + 4] == "<!--" do return i
	case:
		if i + 1 < len(line) && line[i] == '/' && line[i + 1] == '/' do return i
	}
	return -1
}

syntax_operator :: proc(c: u8) -> bool {
	switch c {
	case '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':':
		return true
	}
	return false
}

write_hl_seg :: proc(b: ^strings.Builder, bg, color, text: string) {
	strings.write_string(b, bg)
	strings.write_string(b, fg_sgr(color))
	strings.write_string(b, text)
	strings.write_string(b, RESET_SGR)
}

// highlight_line returns a fully styled line for the code box: background,
// per-token foreground, reset, background re-opened, then EL. The background is
// deliberately left active: the screen manager emits another EL after every
// tail line, and that clear must paint the same code-block background instead
// of the terminal default. The Go renderer relies on the same invariant.
highlight_line :: proc(lang, line: string) -> string {
	b := strings.builder_make()
	bg := bg_sgr("233")
	l := strings.to_lower(strings.trim_space(lang), context.temp_allocator)

	if l == "diff" || l == "patch" {
		color := "231"
		if strings.has_prefix(line, "-") do color = "197"
		else if strings.has_prefix(line, "+") do color = "148"
		else if strings.has_prefix(line, "@@") do color = "81"
		write_hl_seg(&b, bg, color, line)
		strings.write_string(&b, bg)
		strings.write_string(&b, EL)
		return strings.to_string(b)
	}

	// CSS/HTML: keep it simple; strings and tags are the useful parts.
	i := 0
	for i < len(line) {
		cs := syntax_comment_start(l, line, i)
		if cs >= 0 {
			write_hl_seg(&b, bg, "242", line[i:])
			i = len(line)
			break
		}
		c := line[i]
		if c == '"' || c == '\'' || c == '`' {
			j := i + 1
			for j < len(line) {
				if line[j] == '\\' && j + 1 < len(line) {
					j += 2
					continue
				}
				if line[j] == c {
					j += 1
					break
				}
				j += 1
			}
			color := "186"
			// JSON object keys are pink.
			if l == "json" {
				k := j
				for k < len(line) && (line[k] == ' ' || line[k] == '\t') do k += 1
				if k < len(line) && line[k] == ':' do color = "197"
			}
			write_hl_seg(&b, bg, color, line[i:j])
			i = j
			continue
		}
		if is_digit(c) {
			j := i
			for j < len(line) && (is_digit(line[j]) || line[j] == '.' || line[j] == 'x' ||
			   (line[j] >= 'a' && line[j] <= 'f') || (line[j] >= 'A' && line[j] <= 'F')) {
				j += 1
			}
			write_hl_seg(&b, bg, "141", line[i:j])
			i = j
			continue
		}
		if is_ident_start(c) {
			j := i
			for j < len(line) && is_ident_char(line[j]) do j += 1
			word := line[i:j]
			color := "231"
			if syntax_keyword(l, word) {
				color = "81"
			} else {
				k := j
				for k < len(line) && (line[k] == ' ' || line[k] == '\t') do k += 1
				if k < len(line) && line[k] == '(' do color = "148"
			}
			write_hl_seg(&b, bg, color, word)
			i = j
			continue
		}
		if syntax_operator(c) {
			j := i + 1
			for j < len(line) && syntax_operator(line[j]) do j += 1
			write_hl_seg(&b, bg, "197", line[i:j])
			i = j
			continue
		}
		j := i
		for j < len(line) {
			cj := line[j]
			if is_ident_start(cj) || is_digit(cj) || cj == '"' || cj == '\'' || cj == '`' ||
			   syntax_operator(cj) || syntax_comment_start(l, line, j) >= 0 {
				break
			}
			j += 1
		}
		if j == i do j += 1
		write_hl_seg(&b, bg, "231", line[i:j])
		i = j
	}
	strings.write_string(&b, bg)
	strings.write_string(&b, EL)
	return strings.to_string(b)
}
