import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Циферблат «Вело»: экран стилизован под велосипедное колесо.
// Обод — кольцо прогресса шагов, спицы — часовые метки, «ниппель» — секунды.
// В центре — время, сверху дата, снизу пульс / батарея / шаги.
class VeloView extends WatchUi.WatchFace {

    private const ACCENT       = Graphics.COLOR_ORANGE;
    private const RIM_DIM      = Graphics.COLOR_DK_GRAY;
    private const TEXT_MAIN    = Graphics.COLOR_WHITE;
    private const TEXT_DIM     = Graphics.COLOR_LT_GRAY;
    private const SLEEP_COLOR  = Graphics.COLOR_LT_GRAY;

    private var _sleeping as Boolean = false;
    private var _burnIn as Boolean = false;

    private var _cx as Number = 0;
    private var _cy as Number = 0;
    private var _r as Number = 0;

    private var _fontTime as FontDefinition = Graphics.FONT_NUMBER_THAI_HOT;
    private var _fontTimeSleep as FontDefinition = Graphics.FONT_NUMBER_MEDIUM;
    private var _fontSmall as FontDefinition = Graphics.FONT_SMALL;
    private var _fontTiny as FontDefinition = Graphics.FONT_TINY;

    function initialize() {
        WatchFace.initialize();
    }

    function onLayout(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        _cx = w / 2;
        _cy = h / 2;
        _r = (w < h ? w : h) / 2;

        var settings = System.getDeviceSettings();
        _burnIn = (settings has :requiresBurnInProtection) && settings.requiresBurnInProtection;

        // На круглых MIP 260–280 px «thai hot» слишком крупный — берём на размер меньше.
        if (_r < 150) {
            _fontTime = Graphics.FONT_NUMBER_HOT;
        }
    }

    function onShow() as Void {
    }

    function onHide() as Void {
    }

    function onExitSleep() as Void {
        _sleeping = false;
        WatchUi.requestUpdate();
    }

    function onEnterSleep() as Void {
        _sleeping = true;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_sleeping && _burnIn) {
            drawSleepFace(dc);
            return;
        }

        drawWheel(dc);
        drawTime(dc, _fontTime, TEXT_MAIN, !_sleeping);
        drawDate(dc, TEXT_DIM);
        drawStats(dc);
    }

    // ---------- always-on для AMOLED: минимум пикселей, без ярких цветов ----------

    private function drawSleepFace(dc as Dc) as Void {
        drawTime(dc, _fontTimeSleep, SLEEP_COLOR, false);
        drawDate(dc, RIM_DIM);
    }

    // ---------- колесо ----------

    private function drawWheel(dc as Dc) as Void {
        var rimR = _r - 7;

        // тёмный обод
        dc.setPenWidth(5);
        dc.setColor(RIM_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(_cx, _cy, rimR);

        // прогресс шагов по ободу (по часовой с 12 часов)
        var info = ActivityMonitor.getInfo();
        var steps = info.steps;
        var goal = info.stepGoal;
        if (steps != null && goal != null && goal > 0 && steps > 0) {
            var pct = steps.toFloat() / goal;
            if (pct > 1.0) { pct = 1.0; }
            var sweep = (360.0 * pct).toNumber();
            dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
            if (sweep >= 360) {
                dc.drawCircle(_cx, _cy, rimR);
            } else if (sweep > 0) {
                var endDeg = 90 - sweep;
                if (endDeg < 0) { endDeg += 360; }
                dc.drawArc(_cx, _cy, rimR, Graphics.ARC_CLOCKWISE, 90, endDeg);
            }
        }

        // спицы — 12 часовых меток, ближе к ободу
        dc.setPenWidth(2);
        for (var i = 0; i < 12; i++) {
            var angle = Math.toRadians(i * 30);
            var major = (i % 3 == 0);
            var inner = rimR - (major ? 22 : 14);
            var outer = rimR - 6;
            var sinA = Math.sin(angle);
            var cosA = Math.cos(angle);
            dc.setColor(major ? TEXT_DIM : RIM_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(
                _cx + (inner * sinA).toNumber(), _cy - (inner * cosA).toNumber(),
                _cx + (outer * sinA).toNumber(), _cy - (outer * cosA).toNumber()
            );
        }
        dc.setPenWidth(1);
    }

    // «ниппель» на ободе — секундная метка
    private function drawValve(dc as Dc, sec as Number) as Void {
        var rimR = _r - 7;
        var angle = Math.toRadians(sec * 6);
        var x = _cx + (rimR * Math.sin(angle)).toNumber();
        var y = _cy - (rimR * Math.cos(angle)).toNumber();
        dc.setColor(TEXT_MAIN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, 5);
        dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, 2);
    }

    // ---------- время ----------

    private function drawTime(dc as Dc, font as FontDefinition, color as ColorType, withSeconds as Boolean) as Void {
        var clock = System.getClockTime();
        var hour = clock.hour;
        var settings = System.getDeviceSettings();
        if (!settings.is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        var text = Lang.format("$1$:$2$", [hour.format("%02d"), clock.min.format("%02d")]);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _cy, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        if (withSeconds) {
            drawValve(dc, clock.sec);
        }
    }

    // ---------- дата ----------

    private function drawDate(dc as Dc, color as ColorType) as Void {
        var now = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var dow = now.day_of_week as String;
        var month = now.month as String;
        var text = Lang.format("$1$ $2$ $3$", [dow.toUpper(), now.day, month.toUpper()]);

        var timeH = dc.getFontHeight(_sleeping && _burnIn ? _fontTimeSleep : _fontTime);
        var y = _cy - timeH / 2 - dc.getFontHeight(_fontSmall) / 2 - 2;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, y, _fontSmall, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---------- пульс / батарея / шаги ----------

    private function drawStats(dc as Dc) as Void {
        var timeH = dc.getFontHeight(_fontTime);
        var rowY = _cy + timeH / 2 + dc.getFontHeight(_fontSmall) / 2;
        var colDx = (_r * 0.42).toNumber();

        // пульс (слева)
        var hr = currentHeartRate();
        drawHeart(dc, _cx - colDx - 22, rowY);
        dc.setColor(TEXT_MAIN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx - colDx - 8, rowY, _fontSmall, hr == null ? "--" : hr.toString(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        // шаги (справа)
        var steps = ActivityMonitor.getInfo().steps;
        dc.setColor(TEXT_MAIN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx + colDx + 8, rowY, _fontSmall, steps == null ? "--" : steps.toString(),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        drawSteps(dc, _cx + colDx + 22, rowY);

        // батарея (внизу по центру) + телефон
        var batteryY = rowY + dc.getFontHeight(_fontSmall) + 4;
        var battery = System.getSystemStats().battery;
        drawBattery(dc, _cx - 10, batteryY, battery);
        dc.setColor(TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx + 16, batteryY, _fontTiny, battery.toNumber().format("%d") + "%",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        if (System.getDeviceSettings().phoneConnected) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(_cx - 24, batteryY, 3);
        }
    }

    private function currentHeartRate() as Number? {
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo.currentHeartRate != null) {
            return activityInfo.currentHeartRate;
        }
        var iter = ActivityMonitor.getHeartRateHistory(1, true);
        var sample = iter.next();
        if (sample != null && sample.heartRate != ActivityMonitor.INVALID_HR_SAMPLE) {
            return sample.heartRate;
        }
        return null;
    }

    // ---------- иконки (рисуем примитивами, чтобы не зависеть от шрифтов) ----------

    private function drawHeart(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x - 3, y - 2, 4);
        dc.fillCircle(x + 3, y - 2, 4);
        dc.fillPolygon([[x - 7, y - 1], [x + 7, y - 1], [x, y + 7]]);
    }

    private function drawSteps(dc as Dc, x as Number, y as Number) as Void {
        // стилизованная шестерёнка-звезда: кружок с 6 зубцами
        dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, 4);
        dc.setPenWidth(2);
        for (var i = 0; i < 6; i++) {
            var a = Math.toRadians(i * 60);
            dc.drawLine(x, y, x + (7 * Math.sin(a)).toNumber(), y - (7 * Math.cos(a)).toNumber());
        }
        dc.setPenWidth(1);
    }

    private function drawBattery(dc as Dc, x as Number, y as Number, pct as Float) as Void {
        var w = 20;
        var h = 10;
        var color = ACCENT;
        if (pct <= 15) {
            color = Graphics.COLOR_RED;
        } else if (pct <= 30) {
            color = Graphics.COLOR_YELLOW;
        }
        dc.setColor(TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawRectangle(x - w / 2, y - h / 2, w, h);
        dc.fillRectangle(x + w / 2, y - 2, 2, 4);
        var fill = ((w - 4) * pct / 100).toNumber();
        if (fill > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x - w / 2 + 2, y - h / 2 + 2, fill, h - 4);
        }
    }
}
