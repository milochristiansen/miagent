package harness

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_attachment_from_path :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/miagent-attachment-test-%d", time.to_unix_nanoseconds(time.now()))
	defer delete(root)
	if !testing.expectf(t, os.make_directory_all(root) == nil, "creating %s", root) do return
	defer os.remove_all(root)

	png_path := join_path(root, "tiny.png")
	md_path := join_path(root, "notes.md")
	bin_path := join_path(root, "blob.bin")
	defer delete(png_path)
	defer delete(md_path)
	defer delete(bin_path)

	png_bytes := []u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0}
	bin_bytes := []u8{0, 1, 2, 3}
	if err := os.write_entire_file(png_path, png_bytes); err != nil do testing.fail_now(t, fmt.aprintf("%v", err))
	if err := os.write_entire_file_from_string(md_path, "# Notes\nhello\n"); err != nil do testing.fail_now(t, fmt.aprintf("%v", err))
	if err := os.write_entire_file(bin_path, bin_bytes); err != nil do testing.fail_now(t, fmt.aprintf("%v", err))

	png, png_err := attachment_from_path(png_path)
	if !testing.expect_value(t, png_err, "") do return
	defer attachment_destroy(&png)
	testing.expect_value(t, png.kind, "image")
	testing.expect_value(t, png.mime, "image/png")
	testing.expect_value(t, png.name, "tiny.png")
	testing.expect(t, strings.has_prefix(png.url, "data:image/png;base64,"))

	md, md_err := attachment_from_path(md_path)
	if !testing.expect_value(t, md_err, "") do return
	defer attachment_destroy(&md)
	testing.expect_value(t, md.kind, "text")
	testing.expect_value(t, md.mime, "text/markdown")
	testing.expect_value(t, md.text, "# Notes\nhello\n")

	bin, bin_err := attachment_from_path(bin_path)
	if !testing.expect_value(t, bin_err, "") do return
	defer attachment_destroy(&bin)
	testing.expect_value(t, bin.kind, "binary")
	testing.expect_value(t, bin.mime, "application/octet-stream")
	testing.expect(t, strings.has_prefix(bin.url, "data:application/octet-stream;base64,"))
}

@(test)
test_user_input_places_attachments_after_prompt :: proc(t: ^testing.T) {
	it := StoredItem{
		role = "user",
		content = strings.clone("Look at these files"),
	}
	it.attachments = make([]Attachment, 2)
	it.attachments[0] = Attachment{
		name = strings.clone("tiny.png"),
		mime = strings.clone("image/png"),
		kind = strings.clone("image"),
		url = strings.clone("data:image/png;base64,AAAA"),
	}
	it.attachments[1] = Attachment{
		name = strings.clone("notes.md"),
		mime = strings.clone("text/markdown"),
		kind = strings.clone("text"),
		text = strings.clone("hello"),
	}
	defer item_destroy(&it)

	v := user_input(it)
	defer json.destroy_value(v)

	obj, ok := jobj(v)
	if !testing.expect(t, ok) do return
	testing.expect_value(t, jstr(jget(obj, "type")), "message")
	testing.expect_value(t, jstr(jget(obj, "role")), "user")

	parts, parts_ok := jarr(jget(obj, "content"))
	if !testing.expect(t, parts_ok) do return
	if !testing.expect_value(t, len(parts), 3) do return

	first, _ := jobj(parts[0])
	testing.expect_value(t, jstr(jget(first, "type")), "input_text")
	testing.expect_value(t, jstr(jget(first, "text")), "Look at these files")

	second, _ := jobj(parts[1])
	testing.expect_value(t, jstr(jget(second, "type")), "input_image")
	testing.expect_value(t, jstr(jget(second, "image_url")), "data:image/png;base64,AAAA")

	third, _ := jobj(parts[2])
	testing.expect_value(t, jstr(jget(third, "type")), "input_text")
	testing.expect(t, strings.contains(jstr(jget(third, "text")), "notes.md"))
	testing.expect(t, strings.contains(jstr(jget(third, "text")), "hello"))
}
