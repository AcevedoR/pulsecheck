#!/usr/bin/env python3
"""Unit tests for the ANSI screen model in tests/screen.py.

The regression harness asserts on what a terminal would show, so a bug in the
model is a bug in every assertion built on it — it once crashed with IndexError
on a line wider than the screen, and silently rendered private-mode sequences
as text. These pin the behaviour the harness depends on.

usage: python3 tests/test_screen.py   (or: python3 -m unittest discover tests)
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen import Screen


def render(data, rows=5, cols=10):
    return Screen(rows, cols).feed(data).text()


class TestPlainText(unittest.TestCase):
    def test_writes_at_the_origin(self):
        self.assertEqual(render("hi")[0], "hi")

    def test_newline_moves_down_and_keeps_the_column(self):
        # No implicit carriage return: a bare \n in awk output must not be
        # rendered as though the cursor went back to column 1.
        self.assertEqual(render("ab\ncd")[:2], ["ab", "  cd"])

    def test_carriage_return_goes_to_column_one(self):
        self.assertEqual(render("abc\rx")[0], "xbc")

    def test_trailing_spaces_are_stripped_by_text(self):
        self.assertEqual(render("hi   ")[0], "hi")


class TestWrapping(unittest.TestCase):
    def test_a_line_wider_than_the_screen_wraps(self):
        # Regression: this used to raise IndexError instead of showing the
        # wrap a user would actually see.
        out = render("abcdefghijkl", cols=10)
        self.assertEqual(out[0], "abcdefghij")
        self.assertEqual(out[1], "kl")

    def test_wrapping_on_the_last_row_scrolls(self):
        out = render("\n\n\n\n" + "abcdefghijkl", rows=5, cols=10)
        self.assertEqual(out[3], "abcdefghij")
        self.assertEqual(out[4], "kl")


class TestCursorAddressing(unittest.TestCase):
    def test_cup_is_one_based(self):
        self.assertEqual(render("\x1b[2;3Hx")[1], "  x")

    def test_bare_cup_homes_the_cursor(self):
        self.assertEqual(render("\x1b[5;5Hx\x1b[Hy")[0], "y")

    def test_cup_beyond_the_screen_clamps(self):
        # A terminal clamps; the model must too, or a row address past the
        # bottom raises instead of showing the clamping.
        out = render("\x1b[99;99Hx", rows=5, cols=10)
        self.assertEqual(out[4], "         x")

    def test_cup_row_zero_clamps_to_the_top(self):
        self.assertEqual(render("\x1b[0;0Hx")[0], "x")


class TestErase(unittest.TestCase):
    def test_el_clears_from_the_cursor_to_the_end_of_the_line(self):
        self.assertEqual(render("abcdef\x1b[1;4H\x1b[K")[0], "abc")

    def test_ed_clears_the_whole_screen(self):
        self.assertEqual(render("ab\ncd\x1b[2J"), [""] * 5)


class TestScrollRegion(unittest.TestCase):
    def test_lf_at_the_bottom_of_the_region_scrolls_only_the_region(self):
        # Rows 2-3 scroll; row 1 (the fixed header) must not move.
        data = "\x1b[2;3r" + "\x1b[1;1Hhdr" + "\x1b[2;1Ha\x1b[3;1Hb" + "\n" + "\rc"
        out = render(data, rows=4, cols=10)
        self.assertEqual(out[0], "hdr")
        self.assertEqual(out[1], "b")
        self.assertEqual(out[2], "c")

    def test_resetting_the_region_restores_the_full_screen(self):
        out = render("\x1b[2;3r\x1b[r\x1b[4;1Hx\ny", rows=5, cols=10)
        self.assertEqual(out[3], "x")
        self.assertEqual(out[4], " y")


class TestIgnoredSequences(unittest.TestCase):
    def test_sgr_colours_leave_no_characters_on_the_grid(self):
        self.assertEqual(render("\x1b[31mred\x1b[0m")[0], "red")

    def test_private_modes_do_not_render_as_text(self):
        # Cursor hide/show and the alternate screen change no cell; before this
        # was handled they leaked "?25l" into the rendered output.
        self.assertEqual(render("\x1b[?25la\x1b[?25h")[0], "a")

    def test_cursor_save_and_restore_are_skipped(self):
        self.assertEqual(render("\x1b7a\x1b8b")[0], "ab")


if __name__ == "__main__":
    unittest.main(verbosity=2)
