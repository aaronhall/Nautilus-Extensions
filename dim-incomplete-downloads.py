# SPDX-License-Identifier: GPL-3.0-or-later
# dim-incomplete-downloads.py — Nautilus extension: dim qBittorrent partials
#
# Dims files ending in ".!qB" (qBittorrent incomplete downloads) so they read
# as "not a file yet". Technique adapted from ToFpon's hidden-dim extensions:
# a timer walks open Files windows and sets cell opacity by label text.
#
# Tune: INCOMPLETE_OPACITY (lower = fainter), SUFFIX, TICK_MS.
#
# Install: symlink into ~/.local/share/nautilus-python/extensions/ and
# restart Nautilus with `nautilus -q`.

from gi.repository import Nautilus, GObject, Gtk, GLib

SUFFIX = ".!qB"
INCOMPLETE_OPACITY = 0.35
FULL_OPACITY = 1.0
TICK_MS = 750


def _first_label_text(widget):
    if isinstance(widget, Gtk.Label):
        return widget.get_text()
    child = widget.get_first_child()
    while child:
        text = _first_label_text(child)
        if text:
            return text
        child = child.get_next_sibling()
    return None


def _process_cell(cell):
    text = _first_label_text(cell)
    if text is None:
        return
    target = INCOMPLETE_OPACITY if text.endswith(SUFFIX) else FULL_OPACITY
    if abs(cell.get_opacity() - target) > 0.01:
        cell.set_opacity(target)


def _walk(widget):
    if type(widget).__name__ in ("NautilusNameCell", "NautilusGridCell"):
        _process_cell(widget)
        return
    child = widget.get_first_child()
    while child:
        _walk(child)
        child = child.get_next_sibling()


def _walk_all_windows(app):
    if app is not None:
        windows = app.get_windows()
    else:
        windows = [w for w in Gtk.Window.list_toplevels()
                   if "Nautilus" in type(w).__name__]
    for win in windows:
        _walk(win)


class IncompleteDownloadsDimmer(GObject.GObject, Nautilus.MenuProvider):
    __gtype_name__ = "IncompleteDownloadsDimmer"

    def __init__(self):
        super().__init__()
        self._app = Gtk.Application.get_default()
        self._pending = False
        if self._app is not None:
            try:
                self._app.connect("window-added", self._on_window_added)
            except Exception:
                pass
        # Idle, not a fixed delay: style the first window at the earliest
        # chance after its widgets exist instead of racing a 300ms timer.
        GLib.idle_add(self._initial_walk)
        GLib.timeout_add(TICK_MS, self._view_tick)

    def _initial_walk(self):
        _walk_all_windows(self._app)
        return False  # one-shot

    def _on_window_added(self, app, window):
        # New window → walk as soon as its widgets exist.
        GLib.idle_add(self._initial_walk)

    def _view_tick(self):
        _walk_all_windows(self._app)
        return True  # repeat

    def _deferred_walk(self):
        _walk_all_windows(self._app)
        self._pending = False
        return False  # one-shot

    def get_file_items(self, files):
        return []

    def get_background_items(self, folder):
        # Folder change → re-walk once Nautilus has rendered the new view.
        if not self._pending:
            self._pending = True
            GLib.timeout_add(150, self._deferred_walk)
        return []
