// Thin C bridge over the bits of Dear ImGui (via cimgui) that are awkward to
// bind from Odin: the large ImGuiIO struct, style setup, font atlas access,
// and varargs helpers.
//
// cimgui passes ImVec2 as a by-value struct named ImVec2_c, so values coming
// back from ig* calls are converted at this boundary.
#include <stdbool.h>
#include <string.h>

#include "imgui.h"
#include "imgui_internal.h"
#include "cimgui.h"

typedef struct GLFWwindow GLFWwindow;

// The backend entry points we use, declared here rather than pulling in
// cimgui_impl.h (which wants GLFW and OpenGL headers we don't otherwise need).
extern "C" {
bool ImGui_ImplGlfw_InitForOpenGL(GLFWwindow *window, bool install_callbacks);
void ImGui_ImplGlfw_Shutdown(void);
void ImGui_ImplGlfw_NewFrame(void);
bool ImGui_ImplOpenGL3_Init(const char *glsl_version);
void ImGui_ImplOpenGL3_Shutdown(void);
void ImGui_ImplOpenGL3_NewFrame(void);
void ImGui_ImplOpenGL3_RenderDrawData(ImDrawData *draw_data);
}

extern "C" {

static inline ImVec2 V2(ImVec2_c v) { return ImVec2(v.x, v.y); }

// --- IO --------------------------------------------------------------------

void mi_io_setup(const char *ini_path) {
  ImGuiIO *io = igGetIO_Nil();
  io->IniFilename = ini_path;
  io->LogFilename = NULL;
  io->ConfigInputTrickleEventQueue = true;
  io->ConfigWindowsMoveFromTitleBarOnly = true;
  io->ConfigWindowsResizeFromEdges = true;
}

void mi_io_display_size(float *w, float *h) {
  ImGuiIO *io = igGetIO_Nil();
  if (w) *w = io->DisplaySize.x;
  if (h) *h = io->DisplaySize.y;
}

float mi_io_dt(void) { return igGetIO_Nil()->DeltaTime; }
int mi_io_want_text_input(void) { return igGetIO_Nil()->WantTextInput; }
int mi_io_want_capture_mouse(void) { return igGetIO_Nil()->WantCaptureMouse; }
int mi_io_key_ctrl(void) { return igGetIO_Nil()->KeyCtrl; }
int mi_io_key_shift(void) { return igGetIO_Nil()->KeyShift; }
int mi_io_key_alt(void) { return igGetIO_Nil()->KeyAlt; }
int mi_io_key_super(void) { return igGetIO_Nil()->KeySuper; }
float mi_io_wheel(void) { return igGetIO_Nil()->MouseWheel; }
float mi_io_time(void) { return (float)igGetTime(); }

void mi_io_set_mouse_cursor(int cursor) {
  igSetMouseCursor((ImGuiMouseCursor)cursor);
}

// Copy queued text input codepoints into caller storage.
int mi_io_input_chars(unsigned int *out, int cap) {
  ImGuiIO *io = igGetIO_Nil();
  ImVector_ImWchar *q = &io->InputQueueCharacters;
  int n = q->Size < cap ? q->Size : cap;
  for (int i = 0; i < n; i++) out[i] = (unsigned int)q->Data[i];
  return n;
}


// --- ordered input events -------------------------------------------------
//
// ImGui keeps the events it consumed this frame in InputEventsTrail. The
// terminal needs their order to associate text with the key that produced it
// and to report key releases/repeats to the Kitty keyboard protocol.
typedef struct MiInputEvent {
  int type;
  int key;
  int down;
  unsigned int ch;
  float analog;
} MiInputEvent;

int mi_io_input_event_count(void) {
  ImGuiContext *ctx = igGetCurrentContext();
  return ctx ? ctx->InputEventsTrail.Size : 0;
}

bool mi_io_input_event_get(int index, MiInputEvent *out) {
  ImGuiContext *ctx = igGetCurrentContext();
  if (ctx == NULL || out == NULL || index < 0 || index >= ctx->InputEventsTrail.Size) return false;
  const ImGuiInputEvent *e = &ctx->InputEventsTrail.Data[index];
  memset(out, 0, sizeof(*out));
  out->type = (int)e->Type;
  switch (e->Type) {
    case ImGuiInputEventType_Key:
      out->key = (int)e->Key.Key;
      out->down = e->Key.Down ? 1 : 0;
      out->analog = e->Key.AnalogValue;
      break;
    case ImGuiInputEventType_Text:
      out->ch = e->Text.Char;
      break;
    case ImGuiInputEventType_Focus:
      out->down = e->AppFocused.Focused ? 1 : 0;
      break;
    default:
      break;
  }
  return true;
}

// --- Fonts -----------------------------------------------------------------

ImFont *mi_font_add(const char *path, float px) {
  ImGuiIO *io = igGetIO_Nil();
  ImFontConfig cfg = {};
  cfg.SizePixels = px;
  cfg.PixelSnapH = true;
  cfg.OversampleH = 1;
  cfg.OversampleV = 1;
  return ImFontAtlas_AddFontFromFileTTF(io->Fonts, path, px, &cfg, NULL);
}

// Merge a fallback font (icons, powerline glyphs, emoji, ...) into an
// explicit target font. Primary-font glyphs win; this only fills the gaps.
ImFont *mi_font_merge(ImFont *dst, const char *path, float px) {
  ImGuiIO *io = igGetIO_Nil();
  ImFontConfig cfg = {};
  cfg.SizePixels = px;
  cfg.PixelSnapH = true;
  cfg.OversampleH = 1;
  cfg.OversampleV = 1;
  cfg.MergeMode = true;
  cfg.DstFont = dst;
  return ImFontAtlas_AddFontFromFileTTF(io->Fonts, path, px, &cfg, NULL);
}

void mi_font_set_default(ImFont *font) { igGetIO_Nil()->FontDefault = font; }
float mi_font_px(ImFont *font) { return font ? font->LegacySize : 0.0f; }
void mi_font_push(ImFont *font) { igPushFont(font, font ? font->LegacySize : 0.0f); }
void mi_font_push_size(ImFont *font, float size) { igPushFont(font, size); }
void mi_font_pop(void) { igPopFont(); }

// --- Text ------------------------------------------------------------------
//
// Text routines take an explicit byte length: Odin strings are not
// NUL-terminated, and ImGui accepts an end pointer, so nothing has to be
// copied or terminated here.

void mi_text_size_n(const char *text, size_t len, float wrap_width, float *w, float *h) {
  ImVec2_c s = igCalcTextSize(text, text + len, false, wrap_width);
  if (w) *w = s.x;
  if (h) *h = s.y;
}

void mi_draw_text_n(ImDrawList *list, float x, float y, unsigned int col,
                    const char *text, size_t len) {
  ImDrawList_AddText_FontPtr(list, igGetFont(), igGetFontSize(),
                             (ImVec2_c){x, y}, (ImU32)col, text, text + len,
                             0.0f, NULL);
}

void mi_draw_text_font_n(ImDrawList *list, ImFont *font, float size, float x,
                         float y, unsigned int col, const char *text, size_t len) {
  ImDrawList_AddText_FontPtr(list, font, size, (ImVec2_c){x, y}, (ImU32)col,
                             text, text + len, 0.0f, NULL);
}

// Draw wrapped text and report the height used.
float mi_draw_text_wrapped_n(ImDrawList *list, float x, float y, float wrap,
                             unsigned int col, const char *text, size_t len) {
  ImVec2_c s = igCalcTextSize(text, text + len, false, wrap);
  ImDrawList_AddText_FontPtr(list, igGetFont(), igGetFontSize(),
                             (ImVec2_c){x, y}, (ImU32)col, text, text + len,
                             wrap, NULL);
  return s.y;
}

// --- Style -----------------------------------------------------------------

void mi_style_apply(float scale) {
  ImGuiStyle *st = igGetStyle();
  igStyleColorsDark(st);
  st->WindowPadding = ImVec2(0, 0);
  // All app panels are explicitly sized; a nonzero minimum would clamp the
  // narrow rail (48px) up to the minimum and make it eat input.
  st->WindowMinSize = ImVec2(1, 1);
  st->WindowRounding = 0;
  st->WindowBorderSize = 0;
  st->ChildRounding = 6.0f * scale;
  st->ChildBorderSize = 1.0f;
  st->PopupRounding = 6.0f * scale;
  st->PopupBorderSize = 1.0f;
  st->FramePadding = ImVec2(10.0f * scale, 7.0f * scale);
  st->FrameRounding = 6.0f * scale;
  st->FrameBorderSize = 0.0f;
  st->ItemSpacing = ImVec2(8.0f * scale, 6.0f * scale);
  st->ItemInnerSpacing = ImVec2(6.0f * scale, 4.0f * scale);
  st->CellPadding = ImVec2(6.0f * scale, 3.0f * scale);
  st->IndentSpacing = 16.0f * scale;
  st->ScrollbarSize = 10.0f * scale;
  st->ScrollbarRounding = 8.0f * scale;
  st->GrabRounding = 6.0f * scale;
  st->GrabMinSize = 10.0f * scale;
  st->TabRounding = 5.0f * scale;
  st->SeparatorTextBorderSize = 1.0f;
  st->FontScaleMain = 1.0f;
}

void mi_style_color(int index, float r, float g, float b, float a) {
  ImGuiStyle *st = igGetStyle();
  if (index < 0 || index >= ImGuiCol_COUNT) return;
  st->Colors[index] = ImVec4(r, g, b, a);
}

// --- Windows ---------------------------------------------------------------

void mi_set_next_window_rect(float x, float y, float w, float h) {
  igSetNextWindowPos((ImVec2_c){x, y}, ImGuiCond_Always, (ImVec2_c){0, 0});
  igSetNextWindowSize((ImVec2_c){w, h}, ImGuiCond_Always);
}

bool mi_begin_overlay(const char *name, float x, float y, float w, float h) {
  mi_set_next_window_rect(x, y, w, h);
  igSetNextWindowBgAlpha(0.0f);
  igSetNextWindowFocus();
  ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration |
                           ImGuiWindowFlags_NoMove |
                           ImGuiWindowFlags_NoSavedSettings |
                           ImGuiWindowFlags_NoScrollbar |
                           ImGuiWindowFlags_NoScrollWithMouse |
                           ImGuiWindowFlags_NoNavFocus;
  return igBegin(name, NULL, flags);
}

bool mi_begin_panel(const char *name, float x, float y, float w, float h,
                    bool interactive) {
  mi_set_next_window_rect(x, y, w, h);
  ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration |
                           ImGuiWindowFlags_NoMove |
                           ImGuiWindowFlags_NoSavedSettings |
                           ImGuiWindowFlags_NoBringToFrontOnFocus |
                           ImGuiWindowFlags_NoNavFocus |
                           ImGuiWindowFlags_NoScrollbar |
                           ImGuiWindowFlags_NoScrollWithMouse |
                           ImGuiWindowFlags_NoBackground;
  if (!interactive) flags |= ImGuiWindowFlags_NoInputs;
  return igBegin(name, NULL, flags);
}

// --- Draw list -------------------------------------------------------------

void mi_draw_rect(ImDrawList *l, float x0, float y0, float x1, float y1,
                  unsigned int col, float rounding) {
  ImDrawList_AddRectFilled(l, (ImVec2_c){x0, y0}, (ImVec2_c){x1, y1}, (ImU32)col,
                           rounding, ImDrawFlags_RoundAll);
}

void mi_draw_rect_round_bottom(ImDrawList *l, float x0, float y0, float x1, float y1,
                               unsigned int col, float rounding) {
  ImDrawList_AddRectFilled(l, (ImVec2_c){x0, y0}, (ImVec2_c){x1, y1}, (ImU32)col,
                           rounding, ImDrawFlags_RoundBottom);
}

void mi_draw_rect_stroke(ImDrawList *l, float x0, float y0, float x1, float y1,
                         unsigned int col, float rounding, float thickness) {
  ImDrawList_AddRect(l, (ImVec2_c){x0, y0}, (ImVec2_c){x1, y1}, (ImU32)col,
                     rounding, thickness, ImDrawFlags_RoundAll);
}

void mi_draw_line(ImDrawList *l, float x0, float y0, float x1, float y1,
                  unsigned int col, float thickness) {
  ImDrawList_AddLine(l, (ImVec2_c){x0, y0}, (ImVec2_c){x1, y1}, (ImU32)col,
                     thickness, 0);
}

void mi_draw_circle(ImDrawList *l, float x, float y, float r, unsigned int col) {
  ImDrawList_AddCircleFilled(l, (ImVec2_c){x, y}, r, (ImU32)col, 0);
}

void mi_draw_image(ImDrawList *l, ImTextureID tex, float x0, float y0,
                   float x1, float y1, float u0, float v0, float u1, float v1,
                   unsigned int col, float rounding) {
  ImTextureRef_c ref = {};
  ref._TexID = tex;
  ImDrawList_AddImageRounded(l, ref,
                             (ImVec2_c){x0, y0}, (ImVec2_c){x1, y1},
                             (ImVec2_c){u0, v0}, (ImVec2_c){u1, v1},
                             (ImU32)col, rounding, ImDrawFlags_RoundAll);
}

void mi_draw_triangle(ImDrawList *l, float ax, float ay, float bx, float by,
                      float cx, float cy, unsigned int col) {
  ImDrawList_AddTriangleFilled(l, (ImVec2_c){ax, ay}, (ImVec2_c){bx, by},
                               (ImVec2_c){cx, cy}, (ImU32)col);
}

void mi_clip_push(ImDrawList *l, float x0, float y0, float x1, float y1) {
  ImDrawList_PushClipRect(l, (ImVec2_c){x0, y0}, (ImVec2_c){x1, y1}, true);
}

void mi_clip_pop(ImDrawList *l) { ImDrawList_PopClipRect(l); }

// --- Interaction -----------------------------------------------------------

bool mi_hit(const char *id, float x, float y, float w, float h) {
  igSetCursorScreenPos((ImVec2_c){x, y});
  return igInvisibleButton(id, (ImVec2_c){w, h}, 0);
}

bool mi_hit_hovered(void) { return igIsItemHovered(0); }
bool mi_hit_clicked(void) { return igIsItemClicked(0); }
bool mi_hit_active(void) { return igIsItemActive(); }

ImVec2_c mi_cursor_screen(void) { return igGetCursorScreenPos(); }

void mi_set_cursor_screen(float x, float y) {
  igSetCursorScreenPos((ImVec2_c){x, y});
}

void mi_get_window_pos(float *x, float *y) {
  ImVec2_c p = igGetWindowPos();
  if (x) *x = p.x;
  if (y) *y = p.y;
}

void mi_get_window_size(float *w, float *h) {
  ImVec2_c s = igGetWindowSize();
  if (w) *w = s.x;
  if (h) *h = s.y;
}

void mi_get_content_avail(float *w, float *h) {
  ImVec2_c s = igGetContentRegionAvail();
  if (w) *w = s.x;
  if (h) *h = s.y;
}

float mi_style_scrollbar(void) { return igGetStyle()->ScrollbarSize; }
float mi_style_frame_padding_x(void) { return igGetStyle()->FramePadding.x; }
float mi_style_frame_padding_y(void) { return igGetStyle()->FramePadding.y; }




void mi_set_clipboard(const char *text) {
  ImGui::SetClipboardText(text);
}

const char *mi_get_clipboard(void) {
  return ImGui::GetClipboardText();
}

void mi_tooltip_n(const char *text, size_t len) {
  if (igBeginTooltip()) {
    igTextUnformatted(text, text + len);
    igEndTooltip();
  }
}

} // extern "C"
