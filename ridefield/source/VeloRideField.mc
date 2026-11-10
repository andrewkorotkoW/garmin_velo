import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Поле данных «Вело заезд» для велотренировки.
// Слева крупная скорость, справа велосипедист: колёса крутятся по пройденной
// дистанции, шатуны — по каденсу, дорога бежит. Стоим — всё замирает.
// Дорога и велосипед наклоняются по уклону; на крутом подъёме райдер встаёт
// на педали, на спуске группируется. Пульс красится по велосипедным зонам.
// Ниже два ряда по три колонки: дистанция, пульс, каденс; средняя, набор, мощность.
//
// Платформа вызывает compute()/onUpdate() раз в секунду, поэтому анимация
// идёт с шагом в кадр в секунду: колёса и дорога шагают по скорости, шатуны —
// по каденсу, независимо друг от друга (накат: колёса крутятся, ноги стоят).
class VeloRideField extends WatchUi.DataField {

    private const ACCENT = Graphics.COLOR_ORANGE;
    private const MOVING_SPEED = 0.5;   // м/с, ниже — считаем, что стоим
    // шаги анимации за кадр (1 кадр = 1 с)
    private const WHEEL_STEP_MIN = 15.0;     // градусов при почти нулевой скорости
    private const WHEEL_STEP_PER_KMH = 3.0;  // + градусов на каждый км/ч
    private const WHEEL_STEP_MAX = 150.0;    // < 180°, иначе читается назад
    private const CRANK_STEP_PER_RPM = 1.0;  // градусов шатунов на каждый об/мин
    private const CRANK_STEP_MIN = 40.0;
    private const CRANK_STEP_MAX = 150.0;
    private const ROAD_PERIOD = 24.0;        // px, период штрихов дороги
    private const ROAD_STEP_MIN = 2.0;
    private const ROAD_STEP_PER_KMH = 0.3;
    private const ROAD_STEP_MAX = 11.0;      // < полупериода
    private const HIST_LEN = 12;        // секунд истории для уклона
    private const GRADE_MIN_DIST = 15.0; // м, минимальная база для расчёта уклона
    private const MAX_TILT = 0.26;      // рад (~15°), предел наклона картинки
    private const STAND_GRADE = 5.0;    // % — с этого подъёма райдер встаёт
    private const TUCK_GRADE = -5.0;    // % — с этого спуска группируется

    private var _speed as Float = 0.0;      // м/с
    private var _avgSpeed as Float = 0.0;   // м/с
    private var _distance as Float = 0.0;   // м
    private var _timerMs as Number = 0;
    private var _hr as Number? = null;
    private var _cadence as Number? = null;
    private var _power as Number? = null;
    private var _ascent as Float? = null;
    private var _moving as Boolean = false;
    private var _wheelDeg as Float = 0.0;   // фаза колеса
    private var _crankDeg as Float = 0.0;   // фаза шатунов
    private var _roadPx as Float = 0.0;     // сдвиг разметки дороги
    private var _metric as Boolean = true;

    // уклон: кольцевой буфер (дистанция, высота) за последние HIST_LEN секунд
    private var _histDist as Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    private var _histAlt as Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    private var _histIdx as Number = 0;
    private var _histCount as Number = 0;
    private var _grade as Float = 0.0;      // %, сглаженный
    private var _hasGrade as Boolean = false;

    // зоны пульса для велосипеда: границы [z1min, z2min, z3min, z4min, z5min, z5max]
    private var _zones as Array<Number>? = null;

    // текущий поворот картинки велосипедиста (см. drawCyclist)
    private var _pivotX as Float = 0.0;
    private var _pivotY as Float = 0.0;
    private var _cosT as Float = 1.0;
    private var _sinT as Float = 0.0;

    function initialize() {
        DataField.initialize();
        _metric = (System.getDeviceSettings().distanceUnits == System.UNIT_METRIC);
        _zones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_BIKING);
    }

    function onLayout(dc as Dc) as Void {
    }

    // Раз в секунду: забираем данные и продвигаем фазы анимации.
    function compute(info as Activity.Info) as Void {
        var speed = info.currentSpeed;
        _speed = (speed != null) ? speed : 0.0;
        var avg = info.averageSpeed;
        _avgSpeed = (avg != null) ? avg : 0.0;
        var dist = info.elapsedDistance;
        _distance = (dist != null) ? dist : 0.0;
        var timer = info.timerTime;
        _timerMs = (timer != null) ? timer : 0;
        _hr = info.currentHeartRate;
        _cadence = info.currentCadence;
        _power = info.currentPower;
        _ascent = info.totalAscent;

        _moving = _speed > MOVING_SPEED;
        if (_moving) {
            // Кадр раз в секунду, поэтому крутим не на физический угол (он даёт
            // стробоскоп: колесо делает 3-4 оборота за кадр), а на визуальный шаг,
            // который растёт со скоростью/каденсом и остаётся меньше полупериода
            // рисунка — тогда движение читается вперёд, а быстрее/медленнее видно.
            var kmh = _speed * 3.6;
            var wheelStep = WHEEL_STEP_MIN + kmh * WHEEL_STEP_PER_KMH;
            if (wheelStep > WHEEL_STEP_MAX) { wheelStep = WHEEL_STEP_MAX; }
            _wheelDeg = wrap360(_wheelDeg + wheelStep);

            var cad = _cadence;
            var cadVal = (cad != null && cad > 0) ? cad.toFloat() : 0.0;
            if (cadVal > 0.0) {
                var crankStep = cadVal * CRANK_STEP_PER_RPM;
                if (crankStep < CRANK_STEP_MIN) { crankStep = CRANK_STEP_MIN; }
                if (crankStep > CRANK_STEP_MAX) { crankStep = CRANK_STEP_MAX; }
                _crankDeg = wrap360(_crankDeg + crankStep);
            }
            // каденс 0 на ходу — накат, ноги стоят, колёса крутятся

            var roadStep = ROAD_STEP_MIN + kmh * ROAD_STEP_PER_KMH;
            if (roadStep > ROAD_STEP_MAX) { roadStep = ROAD_STEP_MAX; }
            _roadPx = wrap(_roadPx + roadStep, ROAD_PERIOD);
        }

        var alt = info.altitude;
        if (dist != null && alt != null) {
            updateGrade(dist, alt);
        }
    }

    // Уклон = перепад высоты / пройденная дистанция за последние секунды,
    // но не короче GRADE_MIN_DIST метров, чтобы шум высотомера не прыгал.
    private function updateGrade(dist as Float, alt as Float) as Void {
        _histDist[_histIdx] = dist;
        _histAlt[_histIdx] = alt;
        _histIdx = (_histIdx + 1) % HIST_LEN;
        if (_histCount < HIST_LEN) { _histCount++; }
        if (!_moving) { return; }

        // ищем самый старый отсчёт, до которого проехали хотя бы GRADE_MIN_DIST
        var best = -1;
        for (var k = 1; k < _histCount; k++) {
            var idx = (_histIdx - 1 - k + HIST_LEN * 2) % HIST_LEN;
            if (dist - _histDist[idx] >= GRADE_MIN_DIST) {
                best = idx;
            }
        }
        if (best < 0) { return; }
        var dDist = dist - _histDist[best];
        var dAlt = alt - _histAlt[best];
        var raw = dAlt / dDist * 100.0;
        if (raw > 30.0) { raw = 30.0; }
        if (raw < -30.0) { raw = -30.0; }
        _grade = _hasGrade ? (_grade * 0.7 + raw * 0.3) : raw;
        _hasGrade = true;
    }

    private function wrap360(a as Float) as Float {
        return wrap(a, 360.0);
    }

    private function wrap(a as Float, period as Float) as Float {
        return a - period * Math.floor(a / period).toFloat();
    }

    // Зона пульса 1..5 по профилю, 0 — зон нет или пульса нет.
    private function hrZone(hr as Number?) as Number {
        var zones = _zones;
        if (hr == null || zones == null || zones.size() < 6) { return 0; }
        var z = 0;
        for (var i = 0; i < 5; i++) {
            if (hr >= zones[i]) { z = i + 1; }
        }
        return z;
    }

    private function zoneColor(zone as Number, fallback as ColorType) as ColorType {
        if (zone == 1) { return Graphics.COLOR_LT_GRAY; }
        if (zone == 2) { return Graphics.COLOR_BLUE; }
        if (zone == 3) { return Graphics.COLOR_GREEN; }
        if (zone == 4) { return Graphics.COLOR_ORANGE; }
        if (zone == 5) { return Graphics.COLOR_RED; }
        return fallback;
    }

    // ---------- отрисовка ----------

    function onUpdate(dc as Dc) as Void {
        var bg = getBackgroundColor();
        var dark = (bg == Graphics.COLOR_BLACK);
        var fg = dark ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var dim = dark ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_DK_GRAY;

        dc.setColor(bg, bg);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        if (w < 200 || h < 200) {
            drawCompact(dc, w, h, fg, dim);
            return;
        }
        drawFull(dc, w, h, fg, dim);
    }

    // Маленькое поле (2+ полей на экране): только скорость и единицы.
    private function drawCompact(dc as Dc, w as Number, h as Number, fg as ColorType, dim as ColorType) as Void {
        var font = (h >= 90) ? Graphics.FONT_NUMBER_MEDIUM : Graphics.FONT_NUMBER_MILD;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2 - 4, font, speedText(_speed), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2 + dc.getFontHeight(font) / 2, Graphics.FONT_XTINY, speedUnit(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Полный экран (одно поле на странице).
    private function drawFull(dc as Dc, w as Number, h as Number, fg as ColorType, dim as ColorType) as Void {
        var cx = w / 2;

        // таймер сверху
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 0.13).toNumber(), Graphics.FONT_SMALL, timerText(_timerMs), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // скорость слева, единицы под ней с отступом
        var speedY = (h * 0.40).toNumber();
        var speedX = (w * 0.30).toNumber();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(speedX, speedY, Graphics.FONT_NUMBER_HOT, speedText(_speed), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        var unitY = speedY + dc.getFontHeight(Graphics.FONT_NUMBER_HOT) / 2 + dc.getFontHeight(Graphics.FONT_XTINY) / 2 + 2;
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(speedX, unitY, Graphics.FONT_XTINY, speedUnit(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // велосипедист справа, над ним уклон
        var scale = (w < h ? w : h) / 454.0;
        var riderX = (w * 0.70).toNumber();
        drawCyclist(dc, riderX, speedY, scale, fg, dim);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(riderX, speedY - (74.0 * scale).toNumber(), Graphics.FONT_XTINY, gradeText(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ряд 1: дистанция / пульс (цвет зоны) / каденс
        var row1 = (h * 0.64).toNumber();
        var label1 = row1 + dc.getFontHeight(Graphics.FONT_MEDIUM) / 2 + dc.getFontHeight(Graphics.FONT_XTINY) / 2;
        var zone = hrZone(_hr);
        var hrLabel = WatchUi.loadResource(Rez.Strings.LabelHr) as String;
        if (zone > 0) { hrLabel = hrLabel + " Z" + zone; }
        drawStat(dc, (w * 0.25).toNumber(), row1, label1, Graphics.FONT_MEDIUM, distText(_distance), WatchUi.loadResource(Rez.Strings.LabelDist) as String, fg, dim);
        drawStat(dc, cx, row1, label1, Graphics.FONT_MEDIUM, numText(_hr), hrLabel, zoneColor(zone, fg), dim);
        drawStat(dc, (w * 0.75).toNumber(), row1, label1, Graphics.FONT_MEDIUM, numText(_cadence), WatchUi.loadResource(Rez.Strings.LabelCad) as String, fg, dim);

        // ряд 2 (ниже круг уже, колонки ближе к центру): средняя / набор / мощность
        var row2 = (h * 0.81).toNumber();
        var label2 = row2 + dc.getFontHeight(Graphics.FONT_SMALL) / 2 + dc.getFontHeight(Graphics.FONT_XTINY) / 2;
        var ascent = _ascent;
        var ascentStr = (ascent != null) ? ascentText(ascent) : "--";
        drawStat(dc, (w * 0.28).toNumber(), row2, label2, Graphics.FONT_SMALL, speedText(_avgSpeed), WatchUi.loadResource(Rez.Strings.LabelAvg) as String, fg, dim);
        drawStat(dc, cx, row2, label2, Graphics.FONT_SMALL, ascentStr, WatchUi.loadResource(Rez.Strings.LabelAscent) as String, fg, dim);
        drawStat(dc, (w * 0.72).toNumber(), row2, label2, Graphics.FONT_SMALL, numText(_power), WatchUi.loadResource(Rez.Strings.LabelPower) as String, fg, dim);
    }

    private function drawStat(dc as Dc, x as Number, y as Number, labelY as Number, font as FontDefinition, value as String, label as String, fg as ColorType, dim as ColorType) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, value, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, labelY, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---------- велосипедист ----------
    // Координаты заданы для масштаба 1.0 (экран 454 px) относительно центра (cx, cy).
    // Вся картинка поворачивается вокруг центра на угол уклона: подъём —
    // дорога уходит вверх вправо, по ходу движения.

    private function drawCyclist(dc as Dc, cx as Number, cy as Number, s as Float, fg as ColorType, dim as ColorType) as Void {
        var tilt = 0.0;
        if (_hasGrade) {
            tilt = Math.atan(_grade / 100.0).toFloat();
            if (tilt > MAX_TILT) { tilt = MAX_TILT; }
            if (tilt < -MAX_TILT) { tilt = -MAX_TILT; }
        }
        _pivotX = cx.toFloat();
        _pivotY = cy.toFloat();
        _cosT = Math.cos(tilt).toFloat();
        _sinT = Math.sin(tilt).toFloat();

        var wheelR = 28.0 * s;
        var rearX = cx - 40.0 * s;
        var frontX = cx + 40.0 * s;
        var hubY = cy + 20.0 * s;

        // дорога: штрихи бегут влево по мере движения
        var roadY = hubY + wheelR + 4.0 * s;
        dc.setPenWidth(2);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        var x0 = cx - 70.0 * s - _roadPx * s;
        var xEnd = cx + 70.0 * s;
        while (x0 < xEnd) {
            var x1 = x0 + 12.0 * s;
            var a = (x0 < cx - 70.0 * s) ? cx - 70.0 * s : x0;
            var b = (x1 > xEnd) ? xEnd : x1;
            if (b > a) {
                line(dc, a, roadY, b, roadY);
            }
            x0 += 24.0 * s;
        }

        // колёса со спицами (фаза — от дистанции)
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        drawWheel(dc, rearX, hubY, wheelR, _wheelDeg, fg);
        drawWheel(dc, frontX, hubY, wheelR, _wheelDeg + 140.0, fg);

        // рама
        var bbX = cx - 6.0 * s;   var bbY = hubY + 2.0 * s;      // каретка
        var seatX = cx - 20.0 * s; var seatY = cy - 12.0 * s;    // верх подседельной
        var headX = cx + 26.0 * s; var headY = cy - 14.0 * s;    // верх рулевой
        var barX = cx + 32.0 * s;  var barY = cy - 18.0 * s;     // руль
        dc.setPenWidth(3);
        dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
        line(dc, rearX, hubY, bbX, bbY);          // нижние перья
        line(dc, rearX, hubY, seatX, seatY);      // верхние перья
        line(dc, bbX, bbY, seatX, seatY);         // подседельная
        line(dc, seatX, seatY, headX, headY);     // верхняя труба
        line(dc, bbX, bbY, headX, headY);         // нижняя труба
        line(dc, headX, headY, frontX, hubY);     // вилка
        line(dc, headX, headY, barX, barY);       // вынос
        line(dc, seatX, seatY, seatX - 4.0 * s, seatY - 8.0 * s); // подседельный штырь
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        line(dc, seatX - 12.0 * s, seatY - 8.0 * s, seatX + 2.0 * s, seatY - 8.0 * s); // седло

        // поза райдера: сидит / встал на педали (подъём) / сгруппировался (спуск)
        var hipX = seatX - 4.0 * s;  var hipY = seatY - 10.0 * s;
        var shX = cx + 8.0 * s;      var shY = cy - 44.0 * s;    // плечо
        if (_moving && _hasGrade && _grade >= STAND_GRADE) {
            hipX = hipX + 10.0 * s; hipY = hipY - 12.0 * s;      // таз над кареткой
            shX = shX + 4.0 * s;    shY = shY - 4.0 * s;
        } else if (_moving && _hasGrade && _grade <= TUCK_GRADE) {
            shX = shX + 6.0 * s;    shY = shY + 12.0 * s;        // плечи к рулю
        }
        dc.setPenWidth(3);
        line(dc, hipX, hipY, shX, shY);           // спина
        line(dc, shX, shY, barX, barY);           // рука
        circle(dc, shX + 7.0 * s, shY - 9.0 * s, 6.0 * s);       // голова

        // шатуны и ноги (фаза — от каденса)
        var crankR = 8.0 * s;
        var rad = Math.toRadians(_crankDeg);
        var p1x = bbX + crankR * Math.sin(rad);  var p1y = bbY - crankR * Math.cos(rad);
        var p2x = bbX - crankR * Math.sin(rad);  var p2y = bbY + crankR * Math.cos(rad);
        dc.setPenWidth(2);
        dc.setColor(dim, Graphics.COLOR_TRANSPARENT);
        line(dc, p1x, p1y, p2x, p2y);             // шатуны
        dc.setPenWidth(3);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        drawLeg(dc, hipX, hipY, p2x, p2y, 28.0 * s); // дальняя нога
        dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
        drawLeg(dc, hipX, hipY, p1x, p1y, 28.0 * s); // ближняя нога
        dc.setPenWidth(1);
    }

    private function drawWheel(dc as Dc, x as Float, y as Float, r as Float, deg as Float, fg as ColorType) as Void {
        dc.setPenWidth(2);
        dc.drawCircle(rx(x, y).toNumber(), ry(x, y).toNumber(), r.toNumber());
        dc.setPenWidth(1);
        for (var i = 0; i < 3; i++) {
            var a = Math.toRadians(deg + i * 60.0);
            var dx = r * Math.sin(a);
            var dy = r * Math.cos(a);
            line(dc, x - dx, y + dy, x + dx, y - dy);
        }
        dc.fillCircle(rx(x, y).toNumber(), ry(x, y).toNumber(), 2);
        // катафот на ободе — по нему видно полный оборот, а не только период спиц
        var m = Math.toRadians(deg);
        var mr = r - 5.0;
        dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
        circle(dc, x + mr * Math.sin(m), y - mr * Math.cos(m), 3.0);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
    }

    // Нога: бедро + голень одинаковой длины len, колено выгнуто вперёд.
    private function drawLeg(dc as Dc, hx as Float, hy as Float, px as Float, py as Float, len as Float) as Void {
        var dx = px - hx;
        var dy = py - hy;
        var d = Math.sqrt(dx * dx + dy * dy).toFloat();
        if (d < 1.0) { d = 1.0; }
        var half = d / 2.0;
        var k = len * len - half * half;
        var off = (k > 0) ? Math.sqrt(k).toFloat() : 0.0;
        // перпендикуляр к бедру, повёрнутый вперёд (в сторону +x)
        var nx = -dy / d;
        var ny = dx / d;
        if (nx < 0) { nx = -nx; ny = -ny; }
        var kx = hx + dx / 2.0 + nx * off;
        var ky = hy + dy / 2.0 + ny * off;
        line(dc, hx, hy, kx, ky);
        line(dc, kx, ky, px, py);
    }

    // Поворот точки вокруг (_pivotX, _pivotY) на угол уклона.
    private function rx(x as Float, y as Float) as Float {
        var dx = x - _pivotX;
        var dy = y - _pivotY;
        return _pivotX + dx * _cosT + dy * _sinT;
    }

    private function ry(x as Float, y as Float) as Float {
        var dx = x - _pivotX;
        var dy = y - _pivotY;
        return _pivotY - dx * _sinT + dy * _cosT;
    }

    private function line(dc as Dc, x1 as Float, y1 as Float, x2 as Float, y2 as Float) as Void {
        dc.drawLine(rx(x1, y1).toNumber(), ry(x1, y1).toNumber(), rx(x2, y2).toNumber(), ry(x2, y2).toNumber());
    }

    private function circle(dc as Dc, x as Float, y as Float, r as Float) as Void {
        dc.fillCircle(rx(x, y).toNumber(), ry(x, y).toNumber(), r.toNumber());
    }

    // ---------- форматирование ----------

    private function speedText(mps as Float) as String {
        var v = _metric ? mps * 3.6 : mps * 2.23694;
        return v.format("%.1f");
    }

    private function speedUnit() as String {
        return WatchUi.loadResource(_metric ? Rez.Strings.UnitKmh : Rez.Strings.UnitMph) as String;
    }

    private function distText(m as Float) as String {
        var v = _metric ? m / 1000.0 : m / 1609.344;
        return v.format("%.2f");
    }

    private function ascentText(m as Float) as String {
        var v = _metric ? m : m * 3.28084;
        return v.toNumber().format("%d");
    }

    private function gradeText() as String {
        if (!_hasGrade) { return "--%"; }
        var sign = (_grade > 0.05) ? "+" : "";
        return sign + _grade.format("%.1f") + "%";
    }

    private function numText(v as Number?) as String {
        return (v == null) ? "--" : v.toString();
    }

    private function timerText(ms as Number) as String {
        var total = ms / 1000;
        var hrs = total / 3600;
        var mins = (total % 3600) / 60;
        var secs = total % 60;
        if (hrs > 0) {
            return Lang.format("$1$:$2$:$3$", [hrs, mins.format("%02d"), secs.format("%02d")]);
        }
        return Lang.format("$1$:$2$", [mins.format("%02d"), secs.format("%02d")]);
    }
}
