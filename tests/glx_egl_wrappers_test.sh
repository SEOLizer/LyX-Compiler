#!/usr/bin/env bash
# tests/glx_egl_wrappers_test.sh — std/qt5_glx.lyx und std/qt5_egl.lyx boten
# ausschliesslich Konstanten und rohe extern-Bindings. Die typisierten Wrapper,
# die der Kommentarblock "Usage pattern" in qt5_egl.lyx als API beschreibt,
# waren nie geschrieben — examples/graphics/glx_test.lyx und qt5_egl_test.lyx
# riefen sie trotzdem auf und liessen sich daher nicht uebersetzen.
#
# Nur uebersetzt wird: die Wrapper rufen libGL/libEGL, die auf einem Buildhost
# ohne GPU/X-Server nicht sinnvoll laufen. Geprueft wird, dass die Signaturen
# existieren und typrichtig sind.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LYXC="${LYXC:-$ROOT/lyxc}"
_g="$(dirname "$0")/lib/lyxc_guard.sh"; [ -f "$_g" ] || _g="$(dirname "$0")/../lib/lyxc_guard.sh"; . "$_g"   # #1294
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok() { echo "PASS $1"; PASS=$((PASS+1)); }
no() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

compiles() { # name, quelltext
  printf "%s" "$2" > "$TMP/c.lyx"
  out=$(cd "$ROOT" && "$LYXC" --std-path="$ROOT" "$TMP/c.lyx" -o "$TMP/c" 2>&1)
  if [ $? -eq 0 ] && [ -f "$TMP/c" ]; then
    ok "$1"
  else
    no "$1" "$(echo "$out" | grep -iE 'error' | head -1)"
  fi
}

compiles "GLX-Wrapper" 'import std.qt5_glx;
fn main(): int64 {
  var ctx: GLXContext := GLXCreateContextLegacy(0, 0, 0, 1);
  if (ctx.valid != 0) { return 1; }          // dpy==0 -> ungueltig, kein Call
  if (GLXMakeCurrent(0, 0, ctx) != 0) { return 2; }
  GLXDestroyContext(0, ctx);                  // No-op auf ungueltigem Kontext
  return 0;
}'

compiles "EGL-Wrapper" 'import std.qt5_egl;
fn main(): int64 {
  var d: EGLDisplay;
  d.display := 0;
  d.initialized := 0;
  if (EGLBindOpenGL(d) != EGL_FALSE) { return 1; }
  if (EGLBindOpenGLES(d) != EGL_FALSE) { return 2; }
  if (EGLTerminate(d) != EGL_FALSE) { return 3; }
  if (EGLCreateContext(d, 0, EGL_NO_CONTEXT, 0) != EGL_NO_CONTEXT) { return 4; }
  if (EGLMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) != EGL_FALSE) { return 5; }
  if (EGLSwapBuffers(d, EGL_NO_SURFACE) != EGL_FALSE) { return 6; }
  return 0;
}'

# Die beiden Beispiele, die die Wrapper motiviert haben.
for ex in graphics/glx_test.lyx graphics/qt5_egl_test.lyx; do
  out=$(cd "$ROOT/examples/$(dirname "$ex")" && "$LYXC" --std-path="$ROOT" "$(basename "$ex")" -o "$TMP/e" 2>&1)
  if [ $? -eq 0 ]; then ok "example $ex"; else no "example $ex" "$(echo "$out" | grep -iE 'error' | head -1)"; fi
done

echo "Ergebnis: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
