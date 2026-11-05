"""Building blocks of the player window: themed controls, cards, rows, pages and dialogs.

Every control is reachable from the keyboard (Tab, then Enter or Space) and
shows a focus ring only for keyboard focus. Lists, dropdowns and number
fields never take the mouse wheel, so the wheel always scrolls the page.
"""
from PySide6.QtCore import (QCoreApplication, QEasingCurve, QEvent, QPointF, QPropertyAnimation, QRectF,
                            QRegularExpression, QSize, Qt, QTimer, Property, Signal)
from PySide6.QtGui import (QColor, QFont, QIcon, QKeySequence, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap,
                           QRegularExpressionValidator, QShortcut)
from PySide6.QtWidgets import (QAbstractButton, QButtonGroup, QComboBox, QCompleter, QDialog, QFrame, QGridLayout, QHBoxLayout,
                               QLabel, QLayout, QLineEdit, QListView, QPushButton, QScrollArea, QSizePolicy, QStyle,
                               QStyledItemDelegate, QVBoxLayout, QWidget)

import launcher_ui_theme as T
from launcher_app import Heading  # a dropdown entry that only labels the options below it


# ----- small helpers -----------------------------------------------------------
def polish(widget):
    """Re-apply the style sheet after a dynamic property changed."""
    widget.style().unpolish(widget)
    widget.style().polish(widget)
    widget.update()


def label(text="", role="body", tone=None, wrap=False, selectable=False):
    widget = QLabel(text)
    widget.setProperty("role", role)
    if tone:
        widget.setProperty("tone", tone)
    widget.setWordWrap(wrap)
    widget.setTextFormat(Qt.TextFormat.PlainText)
    if selectable:
        widget.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
    if wrap:
        widget.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        widget.setMinimumWidth(10)
    return widget


def set_tone(widget, tone):
    widget.setProperty("tone", tone or "")
    polish(widget)


def rule():
    line = QFrame()
    line.setObjectName("Rule")
    line.setFixedHeight(1)
    return line


def hbox(*items, spacing=T.S3, margins=(0, 0, 0, 0)):
    layout = QHBoxLayout()
    layout.setSpacing(spacing)
    layout.setContentsMargins(*margins)
    for item in items:
        if item is None:
            layout.addStretch(1)
        elif isinstance(item, int):
            layout.addSpacing(item)
        elif isinstance(item, QLayout):
            layout.addLayout(item)
        else:
            layout.addWidget(item)
    return layout


def vbox(*items, spacing=T.S2, margins=(0, 0, 0, 0)):
    layout = QVBoxLayout()
    layout.setSpacing(spacing)
    layout.setContentsMargins(*margins)
    for item in items:
        if item is None:
            layout.addStretch(1)
        elif isinstance(item, int):
            layout.addSpacing(item)
        elif isinstance(item, QLayout):
            layout.addLayout(item)
        else:
            layout.addWidget(item)
    return layout


def holder(layout):
    if isinstance(layout, QGridLayout):
        layout.setContentsMargins(0, 0, 0, 0)
    widget = QWidget()
    widget.setLayout(layout)
    return widget


def clear(layout):
    """Remove every item of a layout, hiding widgets first so none flashes as its own window."""
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is not None:
            widget.hide()
            widget.deleteLater()
        elif item.layout() is not None:
            clear(item.layout())
            item.layout().deleteLater()


def show_new(layout):
    """Show the widgets a layout holds (through nested layouts) unless they were hidden on purpose."""
    for index in range(layout.count()):
        item = layout.itemAt(index)
        widget = item.widget()
        if widget is not None:
            if not widget.testAttribute(Qt.WidgetAttribute.WA_WState_ExplicitShowHide):
                widget.show()
        elif item.layout() is not None:
            show_new(item.layout())


def glyph(kind, color=T.TEXT_2, size=16):
    """A crisp vector icon drawn at twice the size: search, clear, eye, eye-off, check, chevron."""
    ratio = 2
    pixmap = QPixmap(size * ratio, size * ratio)
    pixmap.fill(Qt.GlobalColor.transparent)
    pixmap.setDevicePixelRatio(ratio)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    pen = QPen(QColor(color), 1.7, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
    painter.setPen(pen)
    s = size
    if kind == "search":
        painter.drawEllipse(QRectF(s * .18, s * .18, s * .5, s * .5))
        painter.drawLine(QPointF(s * .6, s * .6), QPointF(s * .84, s * .84))
    elif kind == "clear":
        painter.drawLine(QPointF(s * .3, s * .3), QPointF(s * .7, s * .7))
        painter.drawLine(QPointF(s * .7, s * .3), QPointF(s * .3, s * .7))
    elif kind in ("eye", "eye-off"):
        path = QPainterPath()
        path.moveTo(s * .1, s * .5)
        path.quadTo(s * .5, s * .08, s * .9, s * .5)
        path.quadTo(s * .5, s * .92, s * .1, s * .5)
        painter.drawPath(path)
        painter.drawEllipse(QRectF(s * .38, s * .38, s * .24, s * .24))
        if kind == "eye-off":
            painter.drawLine(QPointF(s * .18, s * .82), QPointF(s * .82, s * .18))
    elif kind in ("minus", "plus"):
        painter.drawLine(QPointF(s * .25, s * .5), QPointF(s * .75, s * .5))
        if kind == "plus":
            painter.drawLine(QPointF(s * .5, s * .25), QPointF(s * .5, s * .75))
    elif kind == "check":
        painter.drawLine(QPointF(s * .22, s * .52), QPointF(s * .42, s * .72))
        painter.drawLine(QPointF(s * .42, s * .72), QPointF(s * .8, s * .3))
    elif kind == "external":
        painter.drawLine(QPointF(s * .45, s * .55), QPointF(s * .8, s * .2))
        painter.drawLine(QPointF(s * .55, s * .2), QPointF(s * .8, s * .2))
        painter.drawLine(QPointF(s * .8, s * .2), QPointF(s * .8, s * .45))
        painter.drawPolyline([QPointF(s * .65, s * .55), QPointF(s * .65, s * .8), QPointF(s * .2, s * .8),
                              QPointF(s * .2, s * .35), QPointF(s * .45, s * .35)])
    painter.end()
    return QIcon(pixmap)


def chevron(painter, center, size, direction, color, width=1.8):
    """A chevron pointing right, down or left, centred on a point."""
    painter.save()
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setPen(QPen(QColor(color), width, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
    x, y, h = center.x(), center.y(), size / 2
    if direction == "down":
        points = [QPointF(x - h, y - h / 2), QPointF(x, y + h / 2), QPointF(x + h, y - h / 2)]
    elif direction == "left":
        points = [QPointF(x + h / 2, y - h), QPointF(x - h / 2, y), QPointF(x + h / 2, y + h)]
    else:
        points = [QPointF(x - h / 2, y - h), QPointF(x + h / 2, y), QPointF(x - h / 2, y + h)]
    painter.drawPolyline(points)
    painter.restore()


# ----- buttons --------------------------------------------------------------------
class Button(QPushButton):
    def __init__(self, text, on_click=None, kind="secondary", size="md", parent=None):
        super().__init__(text.replace("&", "&&"), parent)
        self.setProperty("kind", kind)
        self.setProperty("size", size)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        # Focus rings show for keyboard focus only; a click never leaves one behind.
        self.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        if on_click is not None:
            self.clicked.connect(lambda checked=False: on_click())


class Mark(QWidget):
    """A round status mark: ok (check), warn (!), off (dash) or a step number."""

    def __init__(self, state="ok", text="", size=20, parent=None):
        super().__init__(parent)
        self.state, self.text, self.diameter = state, text, size
        self.setFixedSize(size, size)

    def set_state(self, state, text=""):
        self.state, self.text = state, text
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = QRectF(1, 1, self.diameter - 2, self.diameter - 2)
        fill, ink = {"ok": (T.GREEN_SOFT, T.GREEN), "warn": (T.AMBER_SOFT, T.AMBER), "error": (T.RED_SOFT, T.RED_TEXT),
                     "active": (T.RED, T.WHITE), "done": (T.GREEN_SOFT, T.GREEN),
                     "waiting": (T.FIELD, T.TEXT_3)}.get(self.state, (T.FIELD, T.TEXT_3))
        painter.setPen(QPen(QColor(ink if self.state not in ("active", "waiting") else fill), 1.2))
        painter.setBrush(QColor(fill))
        painter.drawEllipse(rect)
        pen = QPen(QColor(ink), 1.8, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)
        d = self.diameter
        if self.text:
            font = T.font(int(d * .55), QFont.Weight.Bold)
            painter.setFont(font)
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, self.text)
        elif self.state in ("ok", "done"):
            painter.drawPolyline([QPointF(d * .3, d * .52), QPointF(d * .45, d * .67), QPointF(d * .72, d * .36)])
        elif self.state in ("warn", "error"):
            painter.drawLine(QPointF(d / 2, d * .28), QPointF(d / 2, d * .56))
            painter.drawPoint(QPointF(d / 2, d * .72))
        else:
            painter.drawLine(QPointF(d * .34, d / 2), QPointF(d * .66, d / 2))


class Switch(QAbstractButton):
    """An animated on/off switch."""

    def __init__(self, checked=False, parent=None):
        super().__init__(parent)
        self.setCheckable(True)
        self.setChecked(checked)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        self.setFixedSize(44, 24)
        self._position = 1.0 if checked else 0.0
        self._animation = QPropertyAnimation(self, b"position", self)
        self._animation.setDuration(140)
        self._animation.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.toggled.connect(self._animate)

    def _animate(self, on):
        self._animation.stop()
        self._animation.setStartValue(self._position)
        self._animation.setEndValue(1.0 if on else 0.0)
        self._animation.start()

    def get_position(self):
        return self._position

    def set_position(self, value):
        self._position = value
        self.update()

    position = Property(float, get_position, set_position)

    def sizeHint(self):
        return QSize(44, 24)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        enabled = self.isEnabled()
        on = QColor(T.RED if enabled else "#5a2a2b")
        off = QColor(T.LINE_STRONG if enabled else T.LINE)
        track = QColor(
            int(off.red() + (on.red() - off.red()) * self._position),
            int(off.green() + (on.green() - off.green()) * self._position),
            int(off.blue() + (on.blue() - off.blue()) * self._position))
        rect = QRectF(1, 2, 42, 20)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(track)
        painter.drawRoundedRect(rect, 10, 10)
        if self.hasFocus():
            painter.setPen(QPen(QColor(T.FOCUS), 1.5))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRoundedRect(QRectF(0.5, 1, 43, 22), 11, 11)
        x = 4 + self._position * 20
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(T.WHITE if enabled else "#8c8c96"))
        painter.drawEllipse(QRectF(x, 5, 14, 14))

    def enterEvent(self, event):
        self.update()

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self.click()
        else:
            super().keyPressEvent(event)


class SwitchControl(QWidget):
    """A switch with its value written beside it, so the state never relies on colour alone."""
    changed = Signal(bool)

    def __init__(self, value, on_change=None, parent=None):
        super().__init__(parent)
        self.text = label("On" if value else "Off", "muted")
        self.text.setMinimumWidth(24)
        self.text.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.switch = Switch(bool(value))
        layout = hbox(self.text, self.switch, spacing=T.S2)
        self.setLayout(layout)
        self.switch.toggled.connect(self._toggled)
        if on_change is not None:
            self.changed.connect(on_change)

    def _toggled(self, on):
        self.text.setText("On" if on else "Off")
        self.changed.emit(on)

    def value(self):
        return self.switch.isChecked()

    def set_value(self, on):
        self.switch.blockSignals(True)
        self.switch.setChecked(bool(on))
        self.switch.set_position(1.0 if on else 0.0)
        self.switch.blockSignals(False)
        self.text.setText("On" if on else "Off")

    def setEnabled(self, enabled):
        super().setEnabled(enabled)
        self.switch.setEnabled(enabled)


class _SegmentButton(QPushButton):
    """One segment; the recommended one is named under it by its Segmented ("Recommended")."""

    def __init__(self, text, recommended=False):
        super().__init__(text)
        self.recommended = recommended

    def minimumSizeHint(self):
        # A segment is never narrower than its words.
        return self.sizeHint()


class Segmented(QWidget):
    """One choice from a few, as joined buttons; the selected one is filled red."""
    changed = Signal(object)

    def __init__(self, options, value=None, on_change=None, parent=None, stretch=False, recommended=None, tips=None):
        super().__init__(parent)
        self.group = QButtonGroup(self)
        self.group.setExclusive(True)
        self.buttons = {}
        layout = hbox(spacing=0)
        options = list(options)
        for index, (stored, text) in enumerate(options):
            button = _SegmentButton(text, recommended is not None and stored == recommended)
            button.setProperty("seg", "true")
            button.setProperty("pos", "only" if len(options) == 1 else "first" if index == 0
                               else "last" if index == len(options) - 1 else "middle")
            button.setCheckable(True)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.setFocusPolicy(Qt.FocusPolicy.TabFocus)
            if stretch:
                button.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
            if index:
                # Joined buttons share one border.
                layout.addSpacing(-1)
            layout.addWidget(button)
            self.group.addButton(button)
            self.buttons[stored] = button
            button.clicked.connect(lambda checked=False, stored=stored: self._chosen(stored))
        if not stretch:
            layout.addStretch(1)
        self.tips = dict(tips or {})
        self.caption = None
        for button in self.buttons.values():
            if button.recommended:
                # The recommended option says so in its own name: a small star after it, nothing boxed.
                button.setText(button.text() + "  ★")
                button.setToolTip("Recommended")
        self.setLayout(layout)
        self.set_value(value)
        if on_change is not None:
            self.changed.connect(on_change)

    def _chosen(self, stored):
        if stored != self._value:
            self._value = stored
            self.changed.emit(stored)

    def set_value(self, value):
        self._value = value
        for stored, button in self.buttons.items():
            button.setChecked(stored == value)
            # A tooltip only says what isn't on screen: another option's line, and which one we recommend.
            tip = "" if stored == value else self.tips.get(stored, "")
            button.setToolTip(tip)
        if value not in self.buttons:
            # No option holds (a Custom preset): nothing reads as chosen.
            self.group.setExclusive(False)
            for button in self.buttons.values():
                button.setChecked(False)
            self.group.setExclusive(True)

    def value(self):
        return self._value


HEADING_ROLE = Qt.ItemDataRole.UserRole + 1


class _CheckDelegate(QStyledItemDelegate):
    """Dropdown rows with room to breathe and a check mark on the current choice."""

    def __init__(self, combo):
        super().__init__(combo)
        self.combo = combo

    def sizeHint(self, option, index):
        size = super().sizeHint(option, index)
        return QSize(size.width() + 36, 44 if index.data(HEADING_ROLE) else max(34, size.height() + 10))

    def paint(self, painter, option, index):
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = QRectF(option.rect).adjusted(2, 1, -2, -1)
        if index.data(HEADING_ROLE):
            # A group heading: a rule above (except the first) and red capitals, so groups read at a glance.
            if index.row():
                painter.setPen(QPen(QColor(T.LINE_STRONG), 1))
                painter.drawLine(QPointF(rect.left() + 8, rect.top() + 4), QPointF(rect.right() - 8, rect.top() + 4))
            painter.setPen(QColor(T.RED_TEXT))
            painter.setFont(T.font(T.OVERLINE + 1, QFont.Weight.Bold, spacing=1.4))
            painter.drawText(rect.adjusted(12, 10, -12, 0), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft,
                             str(index.data(Qt.ItemDataRole.DisplayRole)).upper())
            painter.restore()
            return
        hovered = bool(option.state & (QStyle.StateFlag.State_MouseOver | QStyle.StateFlag.State_Selected))
        if hovered:
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QColor(T.HOVER))
            painter.drawRoundedRect(rect, 6, 6)
        if index.model() is self.combo.model():
            current = index.row() == self.combo.currentIndex()
        else:  # a row of the search suggestions
            current = str(index.data(Qt.ItemDataRole.DisplayRole)) == self.combo.itemText(self.combo.currentIndex())
        painter.setPen(QColor(T.WHITE if current or hovered else T.TEXT_2))
        font = QFont(option.font)
        font.setWeight(QFont.Weight.DemiBold if current else QFont.Weight.Normal)
        painter.setFont(font)
        text_rect = rect.adjusted(12, 0, -32, 0)
        painter.drawText(text_rect, Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft,
                         str(index.data(Qt.ItemDataRole.DisplayRole)))
        if current:
            pen = QPen(QColor(T.RED_TEXT), 1.8, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
            painter.setPen(pen)
            x, y = rect.right() - 20, rect.center().y()
            painter.drawPolyline([QPointF(x - 5, y), QPointF(x - 1.5, y + 3.5), QPointF(x + 5, y - 4)])
        painter.restore()


class Dropdown(QComboBox):
    """A themed dropdown of (stored value, label) options; picking one calls on_change(stored value)."""
    chosen = Signal(object)
    searching = Signal(str, bool)  # what is typed in a searchable dropdown, and whether any option matches it
    reverted = Signal(str, str)  # text that named no option was left in the box: (that text, the option kept)

    def __init__(self, options, value=None, on_change=None, width=None, parent=None, searchable=False):
        super().__init__(parent)
        self.searchable = searchable
        self.setView(QListView())
        self.view().setItemDelegate(_CheckDelegate(self))
        self.view().setVerticalScrollMode(QListView.ScrollMode.ScrollPerPixel)
        self.setMaxVisibleItems(12)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        self.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToContentsOnFirstShow)
        self.wanted = width
        if width:
            # Every dropdown given a width is that wide, so a card's controls line up; narrower only when the
            # row is (never past the card's edge).
            self.setMaximumWidth(width)
            self.setMinimumWidth(min(width, 200))
            self.setSizePolicy(QSizePolicy.Policy.Maximum, QSizePolicy.Policy.Fixed)
        popup = self.view().window()
        popup.setWindowFlags(Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint
                             | Qt.WindowType.NoDropShadowWindowHint)
        popup.setStyleSheet(f"background: {T.RAISED}; border: 1px solid {T.LINE_STRONG}; border-radius: 8px;")
        if searchable:
            # Type to filter: the field searches every option; the arrow still opens the grouped list.
            self.setEditable(True)
            self.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
            self.lineEdit().setStyleSheet("border: none; background: transparent; padding: 0; min-height: 0;")
            self.lineEdit().setPlaceholderText("Type to search")
            self.lineEdit().editingFinished.connect(self._restore_text)
            self.lineEdit().textChanged.connect(self._typed)
        self.set_options(options, value)
        self.activated.connect(self._activated)
        if on_change is not None:
            self.chosen.connect(on_change)

    def sizeHint(self):
        hint = super().sizeHint()
        return QSize(self.wanted, hint.height()) if self.wanted else hint

    def set_options(self, options, value=None):
        self.blockSignals(True)
        self.clear()
        items = list(options.items()) if isinstance(options, dict) else list(options)
        for stored, text in items:
            self.addItem(str(text), stored)
            if isinstance(stored, Heading):
                item = self.model().item(self.count() - 1)
                item.setData(True, HEADING_ROLE)
                item.setEnabled(False)
                item.setSelectable(False)
        choosable = [i for i, (stored, _) in enumerate(items) if not isinstance(stored, Heading)]
        index = next((i for i, (stored, _) in enumerate(items) if stored == value), choosable[0] if choosable else -1)
        self.setCurrentIndex(index)
        if self.searchable:
            names = [str(text) for stored, text in items if not isinstance(stored, Heading)]
            completer = QCompleter(names, self)
            completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
            completer.setFilterMode(Qt.MatchFlag.MatchContains)
            completer.setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
            completer.setMaxVisibleItems(10)
            popup = completer.popup()
            popup.setFont(T.font())
            popup.setUniformItemSizes(True)
            popup.setItemDelegate(_CheckDelegate(self))
            popup.setVerticalScrollMode(QListView.ScrollMode.ScrollPerPixel)
            popup.setStyleSheet(f"QListView {{ background: {T.RAISED}; color: {T.TEXT}; border: 1px solid {T.LINE_STRONG}; "
                                f"border-radius: 8px; padding: 4px; outline: 0; }}")
            completer.activated.connect(self._picked_text)
            popup.installEventFilter(self)
            self.setCompleter(completer)
        self.blockSignals(False)

    # Search suggestions show at least this many rows when that many match, above the field if needed.
    SUGGESTION_ROWS = 6

    def eventFilter(self, watched, event):
        completer = self.completer()
        if completer is not None and watched is completer.popup() and event.type() == QEvent.Type.Show:
            QTimer.singleShot(0, self._fit_suggestions)
        return super().eventFilter(watched, event)

    def _fit_suggestions(self):
        """Qt shrinks the suggestions to the room below the field (two rows near the window's foot):
        keep a readable list, at least the field's width, flipped above the field when below is short."""
        completer = self.completer()
        popup = completer.popup() if completer is not None else None
        if popup is None or not popup.isVisible():
            return
        rows = min(completer.completionCount(), completer.maxVisibleItems())
        if rows <= 0:
            return
        frame = popup.frameWidth() * 2 + 10
        wanted = popup.sizeHintForRow(0) * rows + frame
        least = popup.sizeHintForRow(0) * min(rows, self.SUGGESTION_ROWS) + frame
        screen = (self.screen() or QCoreApplication.instance().primaryScreen()).availableGeometry()
        top_left = self.mapToGlobal(self.rect().bottomLeft())
        above = self.mapToGlobal(self.rect().topLeft()).y() - screen.top()
        below = screen.bottom() - top_left.y()
        width = max(popup.width(), self.width())
        if below >= least or below >= above:
            height = max(min(wanted, below), min(least, below))
            popup.setGeometry(top_left.x(), top_left.y(), width, height)
        else:
            height = min(wanted, above)
            popup.setGeometry(top_left.x(), self.mapToGlobal(self.rect().topLeft()).y() - height, width, height)

    def _picked_text(self, text):
        index = self.findText(text, Qt.MatchFlag.MatchFixedString)
        if index >= 0 and not self.model().item(index).data(HEADING_ROLE):
            self.setCurrentIndex(index)
            self._activated(index)

    def names(self):
        return [self.itemText(i) for i in range(self.count()) if not self.model().item(i).data(HEADING_ROLE)]

    def _typed(self, text):
        """Tell the page whether anything matches, the same way the suggestions do (any part of a name, any case)."""
        lowered = text.strip().casefold()
        self.searching.emit(text, not lowered or any(lowered in name.casefold() for name in self.names()))

    def chosen_text(self):
        """The chosen option's name; for a searchable box currentText() is whatever is typed."""
        return self.itemText(self.currentIndex())

    def _restore_text(self):
        """Leaving the field with half a name keeps the chosen option."""
        if self.lineEdit() is not None and self.lineEdit().text() != self.chosen_text():
            index = self.findText(self.lineEdit().text().strip(), Qt.MatchFlag.MatchFixedString)
            if index >= 0 and not self.model().item(index).data(HEADING_ROLE):
                self.setCurrentIndex(index)
                self._activated(index)
                self.searching.emit(self.chosen_text(), True)
            else:
                typed = self.lineEdit().text().strip()
                self.lineEdit().setText(self.chosen_text())
                self.searching.emit(self.chosen_text(), True)
                if typed:
                    self.reverted.emit(typed, self.chosen_text())

    def value(self):
        return self.currentData()

    def select(self, stored):
        """Choose an option as if the player had picked it."""
        index = self.findData(stored)
        if index < 0:
            index = self.findText(str(stored))
        if index >= 0:
            self.setCurrentIndex(index)
            self._activated(index)

    def labels(self):
        return [self.itemText(i) for i in range(self.count())]

    def _activated(self, index):
        self.chosen.emit(self.itemData(index))

    def wheelEvent(self, event):
        event.ignore()  # the page scrolls; a value never changes by accident

    def paintEvent(self, event):
        super().paintEvent(event)
        painter = QPainter(self)
        color = T.TEXT_2 if self.isEnabled() else T.DISABLED
        chevron(painter, QPointF(self.width() - 18, self.height() / 2 + 1), 8, "down", color, 1.6)


class TextField(QLineEdit):
    """A text field with a placeholder, an optional clear button and a show/hide eye for secrets."""

    def __init__(self, text="", placeholder="", secret=False, clearable=False, search=False, width=None, parent=None):
        super().__init__(text, parent)
        self.setPlaceholderText(placeholder)
        if width:
            self.setFixedWidth(width)
        if search:
            self.addAction(glyph("search", T.TEXT_3), QLineEdit.ActionPosition.LeadingPosition)
        self._clear = None
        if clearable:
            self._clear = self.addAction(glyph("clear", T.TEXT_2), QLineEdit.ActionPosition.TrailingPosition)
            self._clear.setToolTip("Clear")
            self._clear.triggered.connect(self.clear)
            self._clear.setVisible(bool(text))
            self.textChanged.connect(lambda value: self._clear.setVisible(bool(value)))
        self._eye = None
        if secret:
            self.setEchoMode(QLineEdit.EchoMode.Password)
            self._eye = self.addAction(glyph("eye", T.TEXT_2), QLineEdit.ActionPosition.TrailingPosition)
            self._eye.setToolTip("Show password")
            self._eye.triggered.connect(self._flip)
            self._eye.setVisible(bool(text))
            self.textChanged.connect(lambda value: self._eye.setVisible(bool(value)))

    def _flip(self):
        hidden = self.echoMode() == QLineEdit.EchoMode.Password
        self.setEchoMode(QLineEdit.EchoMode.Normal if hidden else QLineEdit.EchoMode.Password)
        self._eye.setIcon(glyph("eye-off" if hidden else "eye", T.TEXT_2))
        self._eye.setToolTip("Hide password" if hidden else "Show password")

    def set_invalid(self, invalid):
        self.setProperty("invalid", "true" if invalid else "false")
        polish(self)


class Stepper(QWidget):
    """A number with − and + either side and its unit after. Only digits can be typed; while the number is
    outside its range a line under the box says the range, and leaving the box keeps the nearest allowed
    value, so only valid numbers are ever committed."""
    committed = Signal(str)
    UNIT_NAMES = {"s": "seconds", "cm": "cm", "%": "%", "°": "°", "m": "m"}

    def __init__(self, value, minimum, maximum, step, unit="", parent=None):
        super().__init__(parent)
        self.minimum, self.maximum, self.step = minimum, maximum, step
        self.whole = float(step).is_integer() and float(minimum).is_integer()
        self.minus = Button("", lambda: self.nudge(-1))
        self.plus = Button("", lambda: self.nudge(1))
        for button, kind in ((self.minus, "minus"), (self.plus, "plus")):
            button.setFixedSize(36, 36)
            button.setStyleSheet("padding: 0;")
            button.setIcon(glyph(kind, T.TEXT, 16))
            button.setToolTip("Less" if kind == "minus" else "More")
        self.field = QLineEdit(str(value))
        self.field.setAlignment(Qt.AlignmentFlag.AlignCenter)
        sign = "-?" if minimum < 0 else ""
        pattern = rf"{sign}\d{{0,6}}" if self.whole else rf"{sign}\d{{0,6}}([.,]\d{{0,3}})?"
        self.field.setValidator(QRegularExpressionValidator(QRegularExpression(pattern), self.field))
        unit_text = {"s": "sec"}.get(unit, unit)
        self.unit = label(unit_text, "muted")
        self.unit.setParent(self.field)
        if unit_text:
            # "3 sec" reads as one value: the unit sits inside the box, after the number.
            room = self.unit.sizeHint().width() + 8
            self.field.setTextMargins(2, 0, room - 6, 0)
            self.field.setFixedWidth(52 + room)
        else:
            self.field.setFixedWidth(64)
            self.unit.hide()
        self.range_text = f"{format(minimum, 'g')}–{format(maximum, 'g')} {self.UNIT_NAMES.get(unit, unit)}".strip()
        self.setToolTip(self.range_text)
        self.field.installEventFilter(self)
        self.message = label("", "help", "warn")
        self.message.setAlignment(Qt.AlignmentFlag.AlignRight)
        self.message.hide()
        self.setLayout(vbox(hbox(self.minus, self.field, self.plus, spacing=T.S1 + 2), self.message, spacing=T.S1))
        self.last = self.field.text()
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(450)
        self._timer.timeout.connect(self.commit)
        self.field.textEdited.connect(self._edited)
        self.field.editingFinished.connect(self.leave)

    def eventFilter(self, watched, event):
        if watched is self.field and event.type() == QEvent.Type.Resize:
            hint = self.unit.sizeHint()
            self.unit.setGeometry(self.field.width() - hint.width() - 12, (self.field.height() - hint.height()) // 2,
                                  hint.width(), hint.height())
        return False

    def _number(self):
        try:
            return float(self.field.text().replace(",", "."))
        except ValueError:
            return None

    def _flag(self, problem):
        self.field.setProperty("invalid", "true" if problem else "false")
        self.field.style().polish(self.field)
        self.message.setText(problem)
        self.message.setVisible(bool(problem))

    def _edited(self, _text):
        number = self._number()
        if number is None or not self.minimum <= number <= self.maximum:
            self._timer.stop()
            self._flag(f"Use {self.range_text}")
        else:
            self._flag("")
            self._timer.start()

    def _clamped(self, number):
        number = min(self.maximum, max(self.minimum, number))
        number = round(number / self.step) * self.step
        return format(int(number) if self.whole else number, ".9g")

    def leave(self):
        """Leaving the box: an empty box gets its last value back, an out-of-range one the nearest allowed."""
        number = self._number()
        self.field.setText(self.last if number is None else self._clamped(number))
        self._flag("")
        self.commit()

    def nudge(self, direction):
        number = self._number()
        self.field.setText(self._clamped((float(self.last) if number is None else number) + direction * self.step))
        self._flag("")
        self.commit()

    def commit(self):
        self._timer.stop()
        number = self._number()
        if number is None or not self.minimum <= number <= self.maximum:
            return
        self.last = self.field.text()
        self.committed.emit(self.field.text().replace(",", "."))

    def set_text(self, text):
        if self.field.text() != text:
            self.field.setText(text)
        self.last = text

    def setEnabled(self, enabled):
        super().setEnabled(enabled)
        for part in (self.minus, self.plus, self.field):
            part.setEnabled(enabled)


# ----- containers -------------------------------------------------------------------
class PathLabel(QLabel):
    """A folder path in full, wrapping after a folder separator when it doesn't fit on one line."""

    def __init__(self, path, parent=None):
        # A zero-width space after each separator gives the line somewhere to break.
        super().__init__(str(path).replace("\\", "\\\u200b").replace("/", "/\u200b"), parent)
        self.path = path
        self.setProperty("role", "muted")
        self.setWordWrap(True)
        self.setMinimumWidth(40)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.setTextInteractionFlags(Qt.TextInteractionFlag.NoTextInteraction)


class Card(QFrame):
    """A raised card; clickable ones highlight on hover and work from the keyboard."""
    clicked = Signal()

    def __init__(self, clickable=False, selected=False, parent=None, padding=(T.S5, T.S4, T.S5, T.S4)):
        super().__init__(parent)
        self.setObjectName("Card")
        self.clickable = clickable
        self.setProperty("selected", "true" if selected else "false")
        self.layout_ = vbox(spacing=T.S1 + 2, margins=padding)
        self.setLayout(self.layout_)
        if clickable:
            self.setCursor(Qt.CursorShape.PointingHandCursor)
            self.setFocusPolicy(Qt.FocusPolicy.TabFocus)
            self.setAttribute(Qt.WidgetAttribute.WA_Hover)

    def add(self, widget, stretch=0):
        self.layout_.addWidget(widget, stretch)
        return widget

    def set_disabled_look(self, disabled):
        self.setProperty("disabled", "true" if disabled else "false")
        polish(self)

    def enterEvent(self, event):
        if self.clickable:
            self.setProperty("hover", "true")
            polish(self)
        super().enterEvent(event)

    def leaveEvent(self, event):
        if self.clickable:
            self.setProperty("hover", "false")
            polish(self)
        super().leaveEvent(event)

    def mouseReleaseEvent(self, event):
        if self.clickable and event.button() == Qt.MouseButton.LeftButton and self.rect().contains(event.position().toPoint()):
            self.clicked.emit()
        super().mouseReleaseEvent(event)

    def keyPressEvent(self, event):
        if self.clickable and event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Space):
            self.clicked.emit()
        else:
            super().keyPressEvent(event)


class ArrowCard(Card):
    """A clickable card with a chevron at its right edge."""

    def paintEvent(self, event):
        super().paintEvent(event)
        if self.clickable:
            painter = QPainter(self)
            color = T.RED_TEXT if self.property("hover") == "true" else T.TEXT_3
            chevron(painter, QPointF(self.width() - 22, self.height() / 2), 10, "right", color)


class Panel(QFrame):
    """A rounded surface holding rows separated by hairlines."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Panel")
        self.layout_ = vbox(spacing=0, margins=(0, 0, 0, 0))
        self.setLayout(self.layout_)
        self.rows = 0

    def add(self, widget):
        if self.rows:
            line = rule()
            line.setContentsMargins(T.S5, 0, T.S5, 0)
            wrap = QWidget()
            wrap.setLayout(hbox(line, margins=(T.S5, 0, T.S5, 0)))
            self.layout_.addWidget(wrap)
        self.layout_.addWidget(widget)
        self.rows += 1
        return widget


class SettingRow(QWidget):
    """A row: name (with an optional tag) and short help on the left, its control on the right."""

    def __init__(self, title, help_text="", control=None, tag=None, tag_tone=None, dim=False, note=None, parent=None):
        super().__init__(parent)
        grid = QGridLayout()
        grid.setContentsMargins(T.S5, T.S2 + 1, T.S5, T.S2 + 1)  # compact rows: long tabs stay short
        grid.setHorizontalSpacing(T.S6)
        grid.setVerticalSpacing(2)
        head = hbox(spacing=T.S2)
        self.title = label(title, "h3")
        if dim:
            self.title.setStyleSheet(f"color: {T.TEXT_3};")
        head.addWidget(self.title)
        if tag:
            chip = label(tag, "tag", tag_tone)
            head.addWidget(chip)
        head.addStretch(1)
        grid.addLayout(head, 0, 0, Qt.AlignmentFlag.AlignVCenter if not (help_text or note) else Qt.AlignmentFlag.AlignTop)
        self.help = label(help_text, "help", wrap=True) if help_text else None
        if self.help is not None:
            grid.addWidget(self.help, 1, 0)
        if note:
            self.note = label(note, "muted", wrap=True)
            grid.addWidget(self.note, 2, 0)
        grid.setColumnStretch(0, 1)
        self.grid = grid
        self.control = control
        self.rows = 3 if note else 2 if help_text else 1
        self.stacked = None
        self.setLayout(grid)
        self._place(False)

    def _place(self, stacked):
        """Beside the text when there is room, under it when there isn't; decided by width alone."""
        if self.control is None or stacked == self.stacked:
            return
        self.stacked = stacked
        self.grid.removeWidget(self.control)
        if stacked:
            self.grid.addWidget(self.control, 3, 0, 1, 2, Qt.AlignmentFlag.AlignLeft)
        else:
            self.grid.addWidget(self.control, 0, 1, self.rows, 1, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)

    def resizeEvent(self, event):
        if self.control is not None:
            needed = max(self.control.minimumSizeHint().width(), self.control.minimumWidth()) + 260
            self._place(event.size().width() < needed)
        super().resizeEvent(event)


class WrapRow(QWidget):
    """Buttons side by side, or one under another when they don't fit; decided by width alone."""

    def __init__(self, widgets, spacing=T.S2, parent=None):
        super().__init__(parent)
        self.widgets, self.spacing = list(widgets), spacing
        self.grid = QGridLayout()
        self.grid.setContentsMargins(0, 0, 0, 0)
        self.grid.setSpacing(spacing)
        self.setLayout(self.grid)
        self.stacked = None
        self._place(False)

    def needed(self):
        return sum(widget.sizeHint().width() for widget in self.widgets) + self.spacing * (len(self.widgets) - 1)

    def minimumSizeHint(self):
        return QSize(max(widget.sizeHint().width() for widget in self.widgets), super().minimumSizeHint().height())

    def _place(self, stacked):
        if stacked == self.stacked:
            return
        self.stacked = stacked
        for widget in self.widgets:
            self.grid.removeWidget(widget)
        for index, widget in enumerate(self.widgets):
            if stacked:
                self.grid.addWidget(widget, index, 0, Qt.AlignmentFlag.AlignLeft)
            else:
                self.grid.addWidget(widget, 0, index)
        count = 1 if stacked else len(self.widgets)
        for index in range(len(self.widgets) + 1):
            self.grid.setColumnStretch(index, 1 if index == count else 0)

    def resizeEvent(self, event):
        self._place(event.size().width() < self.needed())
        super().resizeEvent(event)


class Callout(QFrame):
    """A tinted box for news, warnings and errors, with optional actions and a dismiss button."""

    def __init__(self, tone, title, text="", actions=(), dismiss=None, parent=None):
        super().__init__(parent)
        self.setObjectName("Callout")
        self.setProperty("tone", tone)
        mark = Mark({"warn": "warn", "error": "error", "ok": "ok"}.get(tone, "info"),
                    "i" if tone == "info" else "", 20)
        if tone == "info":
            mark.state = "waiting"
        lines = vbox(spacing=T.S1 + 1)
        if title:
            heading = label(title, "h3")
            lines.addWidget(heading)
        self.text = label(text, "help", wrap=True) if text else None
        if self.text is not None:
            lines.addWidget(self.text)
        self.body = lines
        if actions:
            row = WrapRow([Button(text_, command, kind=kind, size="sm") for text_, command, kind in actions])
            row.setContentsMargins(0, T.S2, 0, 0)
            lines.addWidget(row)
        layout = QHBoxLayout()
        layout.setContentsMargins(T.S4, T.S3 + 2, T.S4, T.S3 + 2)
        layout.setSpacing(T.S3)
        layout.addWidget(mark, 0, Qt.AlignmentFlag.AlignTop)
        layout.addLayout(lines, 1)
        if dismiss is not None:
            close = QPushButton()
            close.setIcon(glyph("clear", T.TEXT_2, 16))
            close.setProperty("kind", "ghost")
            close.setFixedSize(28, 28)
            close.setStyleSheet("padding: 0; min-height: 28px;")
            close.setToolTip("Dismiss")
            close.setCursor(Qt.CursorShape.PointingHandCursor)
            close.clicked.connect(dismiss)
            layout.addWidget(close, 0, Qt.AlignmentFlag.AlignTop)
        self.setLayout(layout)


def section(text, right=None, top=T.S8):
    """A small capitals label opening a section, with an optional widget at its right."""
    row = QWidget()
    layout = hbox(label(text.upper(), "overline"), None, margins=(2, top, 0, T.S2))
    if right is not None:
        layout.addWidget(right)
    row.setLayout(layout)
    return row


class Accordion(QWidget):
    """A collapsible group: a header bar with a chevron, title and count; the body shows when open."""
    toggled = Signal(bool)

    def __init__(self, title, summary="", opened=False, enabled=True, parent=None):
        super().__init__(parent)
        self.opened = opened and enabled
        self.enabled_ = enabled
        self.header = Card(clickable=enabled, padding=(T.S4, T.S3, T.S4, T.S3))
        self.header.setObjectName("Card")
        head = hbox(spacing=T.S3)
        self.arrow = QWidget()
        self.arrow.setFixedSize(16, 16)
        self.arrow.paintEvent = self._paint_arrow
        head.addWidget(self.arrow)
        name = label(title, "h3")
        if not enabled:
            name.setStyleSheet(f"color: {T.TEXT_3};")
        head.addWidget(name)
        head.addStretch(1)
        self.summary = label(summary, "muted")
        head.addWidget(self.summary)
        self.header.layout_.addLayout(head)
        self.body = QWidget()
        self.body_layout = vbox(spacing=0, margins=(0, T.S2, 0, 0))
        self.body.setLayout(self.body_layout)
        self.body.setVisible(self.opened)
        layout = vbox(self.header, self.body, spacing=0)
        self.setLayout(layout)
        if enabled:
            self.header.clicked.connect(self.flip)

    def _paint_arrow(self, event):
        painter = QPainter(self.arrow)
        color = T.RED_TEXT if self.enabled_ else T.DISABLED
        if self.enabled_:
            chevron(painter, QPointF(8, 8), 9, "down" if self.opened else "right", color)
        else:
            painter.setPen(QPen(QColor(color), 1.6))
            painter.drawLine(QPointF(4, 8), QPointF(12, 8))

    def flip(self):
        self.set_open(not self.opened)
        self.toggled.emit(self.opened)

    def set_open(self, opened):
        self.opened = opened and self.enabled_
        self.body.setVisible(self.opened)
        self.arrow.update()


# ----- page frame -------------------------------------------------------------------
def gutter(width):
    return T.NARROW_GUTTER if width < T.NARROW + 2 * T.GUTTER else T.GUTTER


class FlowGrid(QWidget):
    """Cards in equal columns that wrap to fewer columns as the space narrows; the count depends on width alone,
    so a page lays out the same way every time. Items added with full=True span every column."""

    def __init__(self, min_column=260, max_columns=3, spacing=T.S3, parent=None):
        super().__init__(parent)
        self.min_column, self.max_columns, self.spacing = min_column, max_columns, spacing
        self.items = []
        self.grid = QGridLayout()
        self.grid.setContentsMargins(0, 0, 0, 0)
        self.grid.setHorizontalSpacing(spacing)
        self.grid.setVerticalSpacing(spacing)
        self.setLayout(self.grid)
        self.columns = 0
        self._arrange(max_columns)

    def add(self, widget, full=False):
        # Equal columns: a card's own preferred width never widens its column.
        widget.setSizePolicy(QSizePolicy.Policy.Ignored, widget.sizePolicy().verticalPolicy())
        self.items.append((widget, full))
        self.columns = 0
        self._arrange(self._count(self.width() or 10_000))
        return widget

    def _count(self, width):
        need = max([self.min_column] + [widget.minimumSizeHint().width() for widget, full in self.items if not full])
        return max(1, min(self.max_columns, (width + self.spacing) // (need + self.spacing)))

    def _arrange(self, columns):
        if columns == self.columns:
            return
        self.columns = columns
        for widget, _ in self.items:
            self.grid.removeWidget(widget)
        row = column = 0
        for widget, full in self.items:
            if full and column:
                row, column = row + 1, 0
            span = columns if full else 1
            self.grid.addWidget(widget, row, column, 1, span)
            column += span
            if column >= columns:
                row, column = row + 1, 0
        for index in range(self.max_columns):
            self.grid.setColumnStretch(index, 1 if index < columns else 0)

    def resizeEvent(self, event):
        self._arrange(self._count(event.size().width()))
        super().resizeEvent(event)


class SplitRow(QWidget):
    """Two parts side by side, or the second under the first when the row is narrower than `below`."""

    def __init__(self, first, second, below=640, spacing=T.S6, align_second=Qt.AlignmentFlag.AlignRight,
                 margins=(0, 0, 0, 0), parent=None):
        super().__init__(parent)
        self.first, self.second, self.below = first, second, below
        self.align = align_second
        self.grid = QGridLayout()
        self.grid.setContentsMargins(*margins)
        self.grid.setHorizontalSpacing(spacing)
        self.grid.setVerticalSpacing(T.S3)
        self.setLayout(self.grid)
        self.stacked = None
        self._place(False)

    def _place(self, stacked):
        if stacked == self.stacked:
            return
        self.stacked = stacked
        for part in (self.first, self.second):
            self.grid.removeWidget(part)
        self.grid.addWidget(self.first, 0, 0)
        if stacked:
            self.grid.addWidget(self.second, 1, 0, Qt.AlignmentFlag.AlignLeft)
            self.grid.setColumnStretch(1, 0)
        else:
            self.grid.addWidget(self.second, 0, 1, self.align | Qt.AlignmentFlag.AlignVCenter)
        self.grid.setColumnStretch(0, 1)

    def resizeEvent(self, event):
        self._place(event.size().width() < self.below)
        super().resizeEvent(event)


class HeroFrame(QFrame):
    """The Quick start card. With the player's own KF2 wallpaper it is drawn behind the card, cover-cropped
    and darkened most on the left where the text sits, inside the card's rounded border (one smooth
    gradient, no seam); without it the stylesheet's plain gradient shows."""
    _cache = {}

    def __init__(self, art_path=None, parent=None):
        super().__init__(parent)
        self.setObjectName("Hero")
        self.art = None
        if art_path:
            key = str(art_path)
            if key not in HeroFrame._cache:
                image = QPixmap(key)
                HeroFrame._cache[key] = image if not image.isNull() else None
            self.art = HeroFrame._cache[key]

    def paintEvent(self, event):
        super().paintEvent(event)
        if self.art is None:
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        rect = QRectF(self.rect()).adjusted(1, 1, -1, -1)
        path = QPainterPath()
        path.addRoundedRect(rect, 11, 11)
        painter.setClipPath(path)
        # Cover: scale the wallpaper to fill the card, keeping its centre-right (KF2's art subject).
        art = self.art
        scale = max(rect.width() / art.width(), rect.height() / art.height())
        w, h = art.width() * scale, art.height() * scale
        left = rect.left() - (w - rect.width()) * 0.7
        top = rect.top() - (h - rect.height()) * 0.35
        painter.drawPixmap(QRectF(left, top, w, h), art, QRectF(art.rect()))
        shade = QLinearGradient(rect.left(), 0, rect.right(), 0)
        shade.setColorAt(0.0, QColor(14, 10, 12, 242))
        shade.setColorAt(0.45, QColor(20, 12, 14, 214))
        shade.setColorAt(1.0, QColor(20, 12, 14, 150))
        painter.fillRect(rect, shade)
        painter.setClipping(False)
        painter.setPen(QPen(QColor("#4a2427"), 1))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 12, 12)


class Centered(QWidget):
    """A strip whose content keeps to the centred column: side margins grow once the window is wide."""

    def __init__(self, layout, top=0, bottom=0, parent=None, reference=None):
        super().__init__(parent)
        self.top, self.bottom = top, bottom
        self.reference = reference
        self.setLayout(layout)
        self._margin = None
        self._apply(T.GUTTER)
        if reference is not None:
            self.set_reference(reference)

    def set_reference(self, reference):
        """Centre on this scroller's width. Its viewport narrows while a scroll bar shows during the first
        layout and widens again once it hides, and this column is not always told: follow the viewport too."""
        self.reference = reference
        reference.installEventFilter(self)
        reference.viewport().installEventFilter(self)

    def _apply(self, margin, right=None):
        right = margin if right is None else right
        if (margin, right) != self._margin:
            self._margin = (margin, right)
            self.layout().setContentsMargins(margin, self.top, right, self.bottom)

    def _fit(self, width):
        if self.reference is not None:
            # Inside a scroller: centre on the whole page, so the column never shifts when a scroll bar appears.
            # The room is the viewport's (what a scroll bar leaves), never this column's own width, which can
            # lag behind or overflow mid-layout and must not feed its own margin.
            total = self.reference.width()
            room = self.reference.viewport().width()
            margin = max(gutter(total), (total - T.COLUMN) // 2)
            self._apply(margin, max(T.S2, margin - max(0, total - room)))
        else:
            self._apply(max(gutter(width), (width - T.COLUMN) // 2))

    def eventFilter(self, watched, event):
        if self.reference is not None and event.type() == QEvent.Type.Resize                 and watched in (self.reference, self.reference.viewport()):
            self._fit(self.width())
        return super().eventFilter(watched, event)

    def resizeEvent(self, event):
        self._fit(event.size().width())
        super().resizeEvent(event)


class ScrollArea(QScrollArea):
    """A vertical scroller whose wheel step suits a settings page."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWidgetResizable(True)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.verticalScrollBar().setSingleStep(26)
        self.viewport().setAutoFillBackground(False)


class Page(QWidget):
    """A page: fixed header (title, subtitle, optional bar), scrolling body, and a fixed footer for actions."""
    nav = "Play"

    def __init__(self, window, title="", subtitle="", scroll=True):
        super().__init__()
        self.window_ = window
        self.state = window.state
        self._back = None
        self._primary = None
        outer = vbox(spacing=0)
        header = vbox(spacing=T.S1)
        self.heading = label(title, "title")
        self.title_row = hbox(self.heading, None, spacing=T.S3)
        header.addLayout(self.title_row)
        self.subtitle = label(subtitle, "lead", wrap=True)
        header.addWidget(self.subtitle)
        # Never setVisible(True) before the header has a parent: it would flash as its own window.
        if not subtitle:
            self.subtitle.hide()
        self.header_extra = vbox(spacing=0)
        header.addLayout(self.header_extra)
        self.header = Centered(header, top=T.S8 - 2, bottom=T.S4)
        outer.addWidget(self.header)
        line = Centered(hbox(rule()))
        outer.addWidget(line)
        self.column = vbox(spacing=T.S2)
        self.content = Centered(self.column, top=T.S4, bottom=T.S8)
        self.content.setObjectName("Column")
        if scroll:
            self.scroller = ScrollArea()
            self.content.set_reference(self.scroller)
            self.scroller.setWidget(self.content)
            outer.addWidget(self.scroller, 1)
        else:
            self.scroller = None
            outer.addWidget(self.content, 1)
        self.footer_frame = QFrame()
        self.footer_frame.setObjectName("Footer")
        self.footer_row = hbox(spacing=T.S3)
        self.footer = Centered(self.footer_row, top=T.S3 + 2, bottom=T.S3 + 2)
        footer_layout = vbox(self.footer, spacing=0)
        self.footer_frame.setLayout(footer_layout)
        self.footer_frame.hide()
        outer.addWidget(self.footer_frame)
        self.setLayout(outer)

    def minimumSizeHint(self):
        return QSize(T.MIN_WIDTH - T.RAIL_NARROW, 360)

    # Below this page height the header is compact (smaller title, tighter margins) so more rows show.
    COMPACT_HEIGHT = 700

    def resizeEvent(self, event):
        compact = event.size().height() < self.COMPACT_HEIGHT
        if compact != getattr(self, "_compact", None):
            self._compact = compact
            self.heading.setStyleSheet(f"font-size: {T.H2 + 4}px;" if compact else "")
            self.header.top, self.header.bottom = (T.S5, T.S3) if compact else (T.S8 - 2, T.S4)
            self.header._margin = None
            self.header._fit(self.header.width())
        super().resizeEvent(event)

    def set_title(self, title, subtitle=None):
        self.heading.setText(title)
        if subtitle is not None:
            self.subtitle.setText(subtitle)
            self.subtitle.setVisible(bool(subtitle))

    def add(self, widget, stretch=0):
        self.column.addWidget(widget, stretch)
        return widget

    def add_layout(self, layout):
        self.column.addLayout(layout)
        return layout

    def rebuild(self, keep_scroll=False):
        """Replace the body in one pass; nothing is painted until the new body is complete."""
        top = self.scroller.verticalScrollBar().value() if (keep_scroll and self.scroller) else 0
        self.setUpdatesEnabled(False)
        try:
            clear(self.column)
            clear(self.footer_row)
            self.footer_frame.hide()
            self._back = self._primary = None
            self.primary_button = self.reason = None  # the old footer's widgets are gone
            self.build()
            self.column.addStretch(1)
            # New children of a visible page are shown and laid out by posted events; handle them now, so the
            # first frame after a rebuild is the finished page, never an empty one.
            # New children of a visible page would be shown by a queued call; show them now, then settle the
            # layout (wrapped text takes a second and third pass), so the first frame is the finished page.
            show_new(self.column)
            show_new(self.footer_row)
            for _ in range(3):
                QCoreApplication.sendPostedEvents(None, QEvent.Type.LayoutRequest)
        finally:
            self.setUpdatesEnabled(True)
        if self.scroller:
            bar = self.scroller.verticalScrollBar()
            if keep_scroll:
                QTimer.singleShot(0, lambda: bar.setValue(top))
            else:
                bar.setValue(0)

    def build(self):
        """Fill the body; pages override this."""

    def set_footer(self, back=None, primary=None, primary_text="Continue", enabled=True, reason="", extra=(),
                   back_text="Back"):
        """Back on the left; the reason it's disabled, extra actions and the one primary action on the right."""
        clear(self.footer_row)
        self._back = back
        if back is not None:
            self.footer_row.addWidget(Button(back_text, back))
        self.footer_row.addStretch(1)
        self.reason = label(reason if not enabled else "", "muted")
        self.footer_row.addWidget(self.reason)
        for widget in extra:
            self.footer_row.addWidget(widget)
        self.primary_button = None
        if primary is not None:
            self.primary_button = Button(primary_text, primary, kind="primary")
            self.primary_button.setEnabled(enabled)
            self.footer_row.addWidget(self.primary_button)
            self._primary = primary
        self.footer_frame.show()
        return self.primary_button

    def allow(self, enabled, reason=""):
        if self.primary_button is not None:
            self.primary_button.setEnabled(enabled)
            self.reason.setText("" if enabled else reason)

    def go_back(self):
        if self._back is not None:
            self._back()

    def go_primary(self):
        if self._primary is not None and self.primary_button is not None and self.primary_button.isEnabled():
            self._primary()


# ----- dialogs ------------------------------------------------------------------------
class Dialog(QDialog):
    """A themed modal over the launcher: title, text, optional detail and buttons."""

    def __init__(self, parent, title, text="", buttons=(("OK", True, "primary"),), tone="info", detail=None, width=480):
        super().__init__(parent)
        self.setWindowFlags(Qt.WindowType.Dialog | Qt.WindowType.FramelessWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setModal(True)
        self.result_value = None
        frame = QWidget()
        frame.setObjectName("Dialog")
        frame.setAttribute(Qt.WidgetAttribute.WA_StyledBackground)
        body = vbox(spacing=T.S3, margins=(T.S6 + 4, T.S6, T.S6 + 4, T.S5))
        accent = QFrame()
        accent.setFixedHeight(3)
        accent.setStyleSheet(f"background: {T.AMBER if tone == 'warn' else T.RED}; border-radius: 1px;")
        accent.setFixedWidth(40)
        body.addWidget(accent)
        heading = label(title, "h2", wrap=True)
        body.addWidget(heading)
        self.setWindowTitle(f"{title} - KF2-VR" if title else "KF2-VR")
        self.content = body
        if text:
            body.addWidget(label(text, "body", wrap=True))
        if detail:
            box = label(detail, "help", wrap=True, selectable=True)
            box.setStyleSheet(f"background: {T.PANEL}; border: 1px solid {T.LINE}; border-radius: 8px; padding: 10px 12px;")
            body.addWidget(box)
        self.extra = vbox(spacing=T.S2)
        body.addLayout(self.extra)
        row = hbox(None, spacing=T.S2, margins=(0, T.S3, 0, 0))
        self.buttons = []
        for text_, value, kind in buttons:
            button = Button(text_, lambda value=value: self.finish(value), kind=kind)
            button.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
            row.addWidget(button)
            self.buttons.append((button, value))
        body.addLayout(row)
        frame.setLayout(body)
        outer = vbox(frame, margins=(0, 0, 0, 0))
        self.setLayout(outer)
        self.setFixedWidth(width)
        if self.buttons:
            # Enter picks the last (primary) button; Escape picks "no" (the first, or the only one).
            self.buttons[-1][0].setDefault(True)
            QTimer.singleShot(0, self.buttons[-1][0].setFocus)

    def finish(self, value):
        self.result_value = value
        self.accept()

    def reject(self):
        if self.result_value is None and self.buttons:
            self.result_value = self.buttons[0][1] if len(self.buttons) > 1 else self.buttons[0][1]
        super().reject()

    def fit(self):
        """Height for the fixed width, so wrapped text never leaves gaps."""
        height = self.layout().totalHeightForWidth(self.width())
        if height > 0:
            self.setFixedHeight(height)

    def run(self):
        parent = self.parentWidget()
        self.fit()
        if parent is not None:
            top = parent.window()
            geometry = top.frameGeometry()
            self.move(geometry.center().x() - self.width() // 2,
                      geometry.top() + max(60, (geometry.height() - self.height()) // 3))
        self.exec()
        return self.result_value


def ask(parent, title, text, yes="Continue", no="Cancel", danger=False, detail=None):
    return bool(Dialog(parent, title, text, ((no, False, "ghost"), (yes, True, "dangerfill" if danger else "primary")),
                       tone="warn" if danger else "info", detail=detail).run())


def alert(parent, title, text, kind="error", detail=None):
    Dialog(parent, title, text, (("OK", True, "primary"),), tone="warn" if kind in ("error", "warn") else "info",
           detail=detail).run()


def shortcut(widget, keys, command):
    action = QShortcut(QKeySequence(keys), widget)
    action.setContext(Qt.ShortcutContext.WindowShortcut)
    action.activated.connect(command)
    return action
