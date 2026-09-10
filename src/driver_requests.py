"""Read-only adapter for the Cheongju BIS website (not a documented public API)."""
import math
import re
import time
from datetime import datetime, timezone

import requests

BASE = 'https://www.dcbis.go.kr'


def local_id(value):
    value = str(value or '').strip()
    if value.startswith('CJB'):
        value = value[3:]
    if not re.fullmatch(r'\d{9}', value):
        raise ValueError('청주 정류장 또는 노선 ID를 확인해주세요.')
    return value


def plate(value):
    # Keep regional prefixes; never match only the final four digits.
    return re.sub(r'\s+', '', str(value or ''))


def rows(session, path, params):
    try:
        response = session.post(BASE + path, data=params, timeout=5)
        response.raise_for_status()
        data = response.json()
        if data.get('resultCode') != 200 or not isinstance(data.get('rows'), list):
            raise ValueError('invalid response')
        return data['rows']
    except (requests.RequestException, ValueError):
        raise ValueError('청주시 차량 조회에 실패했습니다. 다시 조회해주세요.') from None


def resolve_vehicle(city, node, route_id, route_no):
    if str(city) != '33010':
        raise ValueError('실제 도착 차량 연결은 현재 청주만 지원합니다.')
    node, route_id = local_id(node), local_id(route_id)
    route_no = str(route_no).strip()
    with requests.Session() as session:
        arrivals = rows(session, '/search/getArriveOpr.do',
                        {'sttnSrvcId': node, 'routeId': route_id})
        received = time.monotonic()
        matching = [r for r in arrivals if str(r.get('routeId')) == route_id
                    and str(r.get('routeNo')) == route_no and str(r.get('msgTp')) == '03']
        # Ambiguous or unsupported responses must not become a vehicle selection.
        if len(matching) != 1:
            raise ValueError('도착 예정 차량을 하나로 확인하지 못했습니다. 다시 조회해주세요.')
        arrival = matching[0]
        vehicle_id = str(arrival.get('vehicleId') or '')
        if not re.fullmatch(r'\d{9}', vehicle_id):
            raise ValueError('도착정보에 차량 ID가 없습니다.')
        route_rows = rows(session, '/search/getRouteView.do', {'routeId': route_id})
    stops = [r for r in route_rows if str(r.get('spotId')) == node]
    stop_numbers = {str(r.get('sttnSrvcId')) for r in stops if r.get('sttnSrvcId')}
    if len(stop_numbers) != 1 or str(arrival.get('sttnSrvcId')) not in stop_numbers:
        raise ValueError('도착정보의 정류장 번호가 선택한 정류장과 다릅니다.')
    vehicles = [r for r in route_rows if str(r.get('busId')) == vehicle_id
                and str(r.get('routeId')) == route_id and str(r.get('routeNo')) == route_no]
    plates = {plate(r.get('busNo')) for r in vehicles if plate(r.get('busNo'))}
    if len(plates) != 1:
        raise ValueError('차량 ID와 번호판을 확정하지 못했습니다.')
    try:
        minutes = float(arrival['arvlPrearngeVwpoint'])
        if not math.isfinite(minutes) or minutes < 0:
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise ValueError('해당 차량의 도착 예정 시간이 없습니다.') from None
    if minutes * 60 <= time.monotonic() - received:
        raise ValueError('도착정보가 변경되었을 수 있습니다. 다시 조회해주세요.')
    return {'cityCode': str(city), 'nodeId': 'CJB' + node, 'routeId': 'CJB' + route_id,
            'routeNo': route_no, 'vehicleId': vehicle_id, 'vehicleNo': next(iter(plates)),
            'stopNumber': next(iter(stop_numbers)), 'direction': arrival.get('sttnAdiNm', ''),
            'arrivalMinutes': minutes, 'remainingStops': arrival.get('sttnLc'),
            'checkedAt': datetime.now(timezone.utc).isoformat(),
            'source': 'cheongju-bis-website', 'vehicleArrivalLinked': True}



def remaining_stops(data, binding, current):
    """Count real stop entries, not gaps in the BIS route's spotSn values."""
    def unavailable(message):
        return {'available': False, 'state': 'unknown', 'message': message}
    try:
        start_id = local_id(binding['nodeId'])
        end_id = local_id(binding.get('dropoffNodeId'))
        route_id = local_id(binding['routeId'])
        by_order = {}
        for item in data:
            if str(item.get('routeId')) != route_id or str(item.get('routeNo')) != binding['routeNo']:
                continue
            if not str(item.get('sttnSrvcId') or '').strip():
                continue
            order = int(str(item['spotSn']))
            node = local_id(str(item['spotId']))
            if order < 0: raise ValueError()
            if order in by_order and by_order[order] != node:
                return unavailable('노선 정류장 순서가 중복되어 하차 순서를 확인하지 못했습니다.')
            by_order[order] = node
        stops = sorted(by_order.items())
        starts = [i for i, (_, node) in enumerate(stops) if node == start_id]
        ends = [i for i, (_, node) in enumerate(stops) if node == end_id]
        # Repeated stop IDs on a loop need an explicit trip occurrence; never wrap around.
        if len(starts) != 1 or len(ends) != 1:
            return unavailable('승차·하차 정류장을 노선에서 하나로 확인하지 못했습니다.')
        start, end = starts[0], ends[0]
        if end <= start:
            return unavailable('선택한 하차 정류장이 승차 정류장보다 앞에 있어 운행 방향을 확인해야 합니다.')
        order = int(str(current['spotSn']))
        node = local_id(str(current['spotId']))
        indices = [i for i, item in enumerate(stops) if item == (order, node)]
        if len(indices) != 1:
            return unavailable('차량 위치를 노선의 정류장 순서와 연결하지 못했습니다.')
        index = indices[0]
        result = {'available': True, 'currentOrder': order, 'boardingOrder': stops[start][0],
                  'dropoffOrder': stops[end][0], 'remainingStops': None,
                  'routeSignature': hashlib.sha256(json.dumps(stops).encode()).hexdigest()}
        if index+1 < len(stops):
            next_order, next_node = stops[index+1]
            result['nextStopId'] = 'CJB'+next_node
            result['nextStop'] = next((str(r.get('routeName') or '') for r in data
                if str(r.get('spotId')) == next_node and str(r.get('spotSn')) == str(next_order)), '')
        if index < start:
            return dict(result, state='before_boarding', message='차량이 아직 승차 정류장에 접근 중입니다. 승차 정류장 이후부터 하차 안내를 시작합니다.')
        if index > end:
            return dict(result, state='passed', message='차량이 하차 정류장 이후 위치로 조회됩니다. 실제 위치를 확인해주세요.')
        return dict(result, state='at_stop' if index == end else 'riding', remainingStops=end-index,
                    message='하차 정류장이 최근 차량 위치로 조회됩니다. 실제 정차 여부를 확인해주세요.' if index == end else '노선 정류장 순서 기준입니다.')
    except (KeyError, TypeError, ValueError):
        return unavailable('하차 정류장 ID 또는 노선 순서 정보가 부족합니다.')


def tracked_position(binding):
    """Query the originally bound vehicle, never the next arrival at the stop."""
    with requests.Session() as session:
        data = rows(session, '/search/getRouteView.do', {'routeId': local_id(binding['routeId'])})
    candidates = [r for r in data
                  if str(r.get('busId')) == binding['vehicleId']
                  and str(r.get('routeId')) == local_id(binding['routeId'])
                  and str(r.get('routeNo')) == binding['routeNo']]
    if not candidates:
        raise ValueError('탑승 요청에 연결된 차량이 현재 운행 목록에 없습니다. 다른 버스로 바꾸지 않고 재조회합니다.')
    if any(plate(r.get('busNo')) != plate(binding['vehicleNo']) for r in candidates):
        raise ValueError('저장된 차량 ID와 현재 번호판이 일치하지 않습니다. 위치를 확정하지 않습니다.')
    # Duplicated identical rows are harmless, conflicting positions are not.
    positions = {(str(r.get('spotId')), str(r.get('spotSn')), str(r.get('xGo')), str(r.get('yGo')))
                 for r in candidates}
    if len(positions) != 1:
        raise ValueError('같은 차량의 위치가 여러 개로 조회되어 위치를 확정하지 못했습니다.')
    row = candidates[0]
    try:
        lon, lat = float(row['xGo']), float(row['yGo'])
        if not (math.isfinite(lon) and math.isfinite(lat) and -180 <= lon <= 180 and -90 <= lat <= 90):
            raise ValueError()
        if lon == 0 and lat == 0: raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise ValueError('해당 차량의 유효한 위치 좌표가 없습니다.') from None
    return {'vehicleId': binding['vehicleId'], 'vehicleNo': binding['vehicleNo'],
            'routeId': binding['routeId'], 'routeNo': binding['routeNo'],
            'latitude': lat, 'longitude': lon,
            'currentNodeId': 'CJB'+str(row.get('spotId') or ''),
            'currentStop': str(row.get('routeName') or '정류장 이름 없음'),
            'stopOrder': row.get('spotSn'),
            'progress': remaining_stops(data, binding, row),
            'checkedAt': datetime.now(timezone.utc).isoformat(),
            'source': 'cheongju-bis-website', 'providerMeasuredAt': None}


"""Local prototype: registered vehicles and durable boarding requests."""
from contextlib import closing
import json
import sqlite3
import hashlib
import secrets
import time
from pathlib import Path
from datetime import datetime, timezone

DB_PATH = Path(__file__).resolve().parent.parent / 'data' / 'driver_requests.sqlite3'

def required(body, key):
    value = body.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > 120:
        raise ValueError(key + ' 값을 확인해주세요.')
    return value.strip()

def trip_response(db, request_id):
    state = db.execute('SELECT state FROM request_status WHERE id=?', (request_id,)).fetchone()
    if not state: return 404, {'ok': False, 'error': '요청이 없습니다.'}
    if state[0] == 'alighted':
        return 200, {'ok': True, 'available': False, 'status': 'alighted', 'message': '하차 완료 · 추적을 종료했습니다.'}
    if state[0] != 'boarded': return 409, {'ok': False, 'error': '탑승 완료 후 위치를 조회할 수 있습니다.'}
    record = db.execute('SELECT binding FROM request_tracking WHERE id=?', (request_id,)).fetchone()
    if not record:
        return 200, {'ok': True, 'available': False, 'status': 'boarded',
            'message': '이 요청에는 추적할 차량 ID가 저장되지 않았습니다. 업데이트 후 실제 차량을 조회해 새 테스트 요청을 보내주세요.'}
    binding = json.loads(record[0])
    try:
        position = tracked_position(binding)
    except ValueError as error:
        return 200, {'ok': True, 'available': False, 'status': 'boarded', 'binding': binding, 'message': str(error)}
    db.execute('BEGIN IMMEDIATE')
    if db.execute('SELECT state FROM request_status WHERE id=?', (request_id,)).fetchone()[0] == 'alighted':
        return 200, {'ok': True, 'available': False, 'status': 'alighted', 'message': '하차 완료 · 추적을 종료했습니다.'}
    progress = position.get('progress', {})
    if progress.get('available'):
        # Serialize progress updates so delayed responses cannot restart earlier alerts.
        previous = db.execute('SELECT last_order, signature FROM trip_progress WHERE id=?', (request_id,)).fetchone()
        if previous and (previous[1] != progress['routeSignature'] or progress['currentOrder'] < previous[0]):
            position['progress'] = {'available': False, 'status': 'boarded', 'state': 'unknown',
                'message': '노선 순서가 바뀌었거나 이전 위치가 조회되어 하차 안내를 보류합니다.'}
        else:
            db.execute('INSERT INTO trip_progress VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET last_order=excluded.last_order',
                       (request_id, progress['currentOrder'], progress['routeSignature']))
    return 200, {'ok': True, 'available': True, 'status': 'boarded', 'binding': binding, 'position': position,
        'message': '요청에 연결된 같은 차량입니다. 제공기관 측정 시각이 없어 위치 지연 여부는 확인할 수 없습니다.'}


def dispatch(method, path, body):
    if path not in ('/driver/register', '/driver/vehicles', '/driver/inbox', '/driver-notifications', '/driver/action', '/boarding/status', '/driver/matched-vehicle', '/test-driver/register', '/test-driver/inbox', '/test-driver/action', '/boarding/location', '/driver/trip', '/test-driver/trip'):
        return None
    try:
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(DB_PATH, timeout=10)) as db, db:
            db.execute('CREATE TABLE IF NOT EXISTS vehicles (vehicle TEXT PRIMARY KEY, route TEXT NOT NULL, token TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, vehicle TEXT NOT NULL, payload TEXT NOT NULL, created TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS request_status (id TEXT PRIMARY KEY, state TEXT NOT NULL, passenger_hash TEXT, confirmed_at TEXT, boarded_at TEXT)')
            if 'alighted_at' not in {r[1] for r in db.execute('PRAGMA table_info(request_status)')}:
                db.execute('ALTER TABLE request_status ADD COLUMN alighted_at TEXT')
            db.execute('CREATE TABLE IF NOT EXISTS vehicle_matches (token TEXT PRIMARY KEY, payload TEXT NOT NULL, expires REAL NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS request_tracking (id TEXT PRIMARY KEY, binding TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS trip_progress (id TEXT PRIMARY KEY, last_order INTEGER NOT NULL, signature TEXT NOT NULL)')
            db.execute('CREATE TABLE IF NOT EXISTS test_clients (token TEXT PRIMARY KEY, expires REAL NOT NULL)')
            if path.startswith('/test-driver/'):
                if method != 'POST': return 405, {'ok': False, 'error': 'POST 요청이 필요합니다.'}
                token = required(body, 'token')
                if len(token) < 32: raise ValueError('테스트 인증값이 너무 짧습니다.')
                digest = hashlib.sha256(token.encode()).hexdigest()
                if path == '/test-driver/register':
                    db.execute('DELETE FROM test_clients WHERE expires<?', (time.time(),))
                    db.execute('INSERT OR REPLACE INTO test_clients VALUES (?,?)', (digest, time.time()+86400))
                    return 200, {'ok': True, 'isTest': True}
                if not db.execute('SELECT 1 FROM test_clients WHERE token=? AND expires>?', (digest, time.time())).fetchone():
                    return 403, {'ok': False, 'error': '테스트 수신 시작을 다시 눌러주세요.'}
                if path == '/test-driver/inbox':
                    result = db.execute("SELECT r.payload, r.created, COALESCE(s.state, 'queued') FROM requests r LEFT JOIN request_status s ON s.id=r.id ORDER BY r.created DESC").fetchall()
                    items = [dict(json.loads(p), createdAt=t, status=state) for p,t,state in result
                             if json.loads(p).get('testAllVehicles') is True and json.loads(p).get('isTest') is True]
                    return 200, {'ok': True, 'requests': items[:100], 'isTest': True}
                if path == '/test-driver/trip':
                    request_id = required(body, 'requestId')
                    row = db.execute('SELECT payload FROM requests WHERE id=?', (request_id,)).fetchone()
                    if not row or not json.loads(row[0]).get('testAllVehicles') or not json.loads(row[0]).get('isTest'):
                        return 403, {'ok': False, 'error': '전용 테스트 요청만 조회할 수 있습니다.'}
                    return trip_response(db, request_id)
                request_id, action = required(body, 'requestId'), required(body, 'action')
                if action not in ('confirm', 'board', 'alight'): raise ValueError('지원하지 않는 동작입니다.')
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT payload FROM requests WHERE id=?', (request_id,)).fetchone()
                if not row or not json.loads(row[0]).get('testAllVehicles') or not json.loads(row[0]).get('isTest'):
                    return 403, {'ok': False, 'error': '전용 테스트 요청만 처리할 수 있습니다.'}
                state = db.execute('SELECT state FROM request_status WHERE id=?', (request_id,)).fetchone()[0]
                now = datetime.now(timezone.utc).isoformat()
                if action == 'confirm' and state == 'queued':
                    db.execute("UPDATE request_status SET state='confirmed', confirmed_at=? WHERE id=?", (now, request_id))
                    state = 'confirmed'
                elif action == 'board':
                    if state == 'queued': return 409, {'ok': False, 'error': '요청 확인을 먼저 눌러주세요.'}
                    if state == 'confirmed':
                        db.execute("UPDATE request_status SET state='boarded', boarded_at=? WHERE id=?", (now, request_id))
                        state = 'boarded'
                elif action == 'alight':
                    if state not in ('boarded', 'alighted'): return 409, {'ok': False, 'error': '탑승 완료 후 하차 완료를 눌러주세요.'}
                    if state == 'boarded':
                        db.execute("UPDATE request_status SET state='alighted', alighted_at=? WHERE id=?", (now, request_id))
                        state = 'alighted'
                return 200, {'ok': True, 'status': state, 'isTest': True}
            if method == 'GET' and path == '/driver/matched-vehicle':
                city, node, route_id, route = (required(body, k) for k in ('cityCode', 'nodeId', 'routeId', 'routeNo'))
                match = resolve_vehicle(city, node, route_id, route)
                if body.get('testMode') == 'true':
                    match['testOnly'] = True
                    token = secrets.token_hex(32)
                    db.execute('DELETE FROM vehicle_matches WHERE expires<?', (time.time(),))
                    db.execute('INSERT INTO vehicle_matches VALUES (?,?,?)',
                               (token, json.dumps(match, ensure_ascii=False), time.time()+60))
                    return 200, {'ok': True, 'match': match, 'matchToken': token, 'vehicles': [],
                                 'message': '조회된 차량을 테스트용으로 연결했습니다.'}
                registered = db.execute('SELECT vehicle FROM vehicles WHERE route=?', (route,)).fetchall()
                candidates = [v for (v,) in registered if plate(v) == plate(match['vehicleNo'])]
                if len(candidates) != 1:
                    return 200, {'ok': True, 'match': match, 'vehicles': [],
                        'message': '도착 예정 차량은 확인됐지만 해당 번호판의 기사 앱 등록을 확인하지 못했습니다.'}
                match['vehicleNo'] = candidates[0]
                token = secrets.token_hex(32)
                db.execute('DELETE FROM vehicle_matches WHERE expires<?', (time.time(),))
                db.execute('INSERT INTO vehicle_matches VALUES (?,?,?)',
                           (token, json.dumps(match, ensure_ascii=False), time.time()+60))
                return 200, {'ok': True, 'match': match, 'matchToken': token,
                    'vehicles': [{'vehicleNo': match['vehicleNo'], 'routeNo': route}],
                    'message': '도착 예정 차량과 등록된 기사 앱이 번호판 기준으로 연결됐습니다. 기사 신원 인증을 뜻하지는 않습니다.'}
            if method == 'POST' and path == '/boarding/location':
                request_id = required(body, 'requestId')
                digest = hashlib.sha256(required(body, 'passengerToken').encode()).hexdigest()
                status = db.execute('SELECT state FROM request_status WHERE id=? AND passenger_hash=?', (request_id, digest)).fetchone()
                if not status: return 403, {'ok': False, 'error': '요청 조회 인증에 실패했습니다.'}
                return trip_response(db, request_id)
            if method == 'POST' and path == '/boarding/status':
                request_id = required(body, 'requestId')
                digest = hashlib.sha256(required(body, 'passengerToken').encode()).hexdigest()
                row = db.execute('SELECT state, confirmed_at, boarded_at, alighted_at FROM request_status WHERE id=? AND passenger_hash=?', (request_id, digest)).fetchone()
                if not row: return 403, {'ok': False, 'error': '요청 조회 인증에 실패했습니다. 새 요청인지 확인하세요.'}
                return 200, {'ok': True, 'requestId': request_id, 'status': row[0], 'confirmedAt': row[1], 'boardedAt': row[2], 'alightedAt': row[3]}
            if method == 'POST' and path == '/driver/trip':
                vehicle, token, request_id = (required(body, k) for k in ('vehicleNo', 'token', 'requestId'))
                digest = hashlib.sha256(token.encode()).hexdigest()
                if not db.execute('SELECT 1 FROM vehicles WHERE vehicle=? AND token=?', (vehicle, digest)).fetchone():
                    return 403, {'ok': False, 'error': '차량 인증에 실패했습니다.'}
                row = db.execute('SELECT payload FROM requests WHERE id=? AND vehicle=?', (request_id, vehicle)).fetchone()
                if not row or json.loads(row[0]).get('testAllVehicles'):
                    return 403, {'ok': False, 'error': '이 차량의 요청이 아닙니다.'}
                return trip_response(db, request_id)
            if method == 'POST' and path == '/driver/action':
                vehicle, token, request_id, action = (required(body, k) for k in ('vehicleNo', 'token', 'requestId', 'action'))
                if action not in ('confirm', 'board', 'alight'): raise ValueError('지원하지 않는 기사 동작입니다.')
                digest = hashlib.sha256(token.encode()).hexdigest()
                db.execute('BEGIN IMMEDIATE')
                if not db.execute('SELECT 1 FROM vehicles WHERE vehicle=? AND token=?', (vehicle, digest)).fetchone():
                    return 403, {'ok': False, 'error': '차량 인증에 실패했습니다.'}
                if not db.execute('SELECT 1 FROM requests WHERE id=? AND vehicle=?', (request_id, vehicle)).fetchone():
                    return 404, {'ok': False, 'error': '이 차량의 요청이 아닙니다.'}
                payload = json.loads(db.execute('SELECT payload FROM requests WHERE id=?', (request_id,)).fetchone()[0])
                if payload.get('testAllVehicles'): return 403, {'ok': False, 'error': '전용 테스트 기사앱에서 처리해주세요.'}
                db.execute("INSERT OR IGNORE INTO request_status(id,state) VALUES (?, 'queued')", (request_id,))
                state = db.execute('SELECT state FROM request_status WHERE id=?', (request_id,)).fetchone()[0]
                now = datetime.now(timezone.utc).isoformat()
                if action == 'confirm' and state == 'queued':
                    db.execute("UPDATE request_status SET state='confirmed', confirmed_at=? WHERE id=?", (now, request_id))
                    state = 'confirmed'
                elif action == 'board':
                    if state == 'queued': return 409, {'ok': False, 'error': '요청 확인을 먼저 눌러주세요.'}
                    if state == 'confirmed':
                        db.execute("UPDATE request_status SET state='boarded', boarded_at=? WHERE id=?", (now, request_id))
                        state = 'boarded'
                elif action == 'alight':
                    if state not in ('boarded', 'alighted'): return 409, {'ok': False, 'error': '탑승 완료 후 하차 완료를 눌러주세요.'}
                    if state == 'boarded':
                        db.execute("UPDATE request_status SET state='alighted', alighted_at=? WHERE id=?", (now, request_id))
                        state = 'alighted'
                return 200, {'ok': True, 'requestId': request_id, 'status': state}
            if method == 'POST' and path == '/driver/register':
                vehicle, route, token = (required(body, k) for k in ('vehicleNo', 'routeNo', 'token'))
                if len(token) < 32: raise ValueError('등록 인증값이 너무 짧습니다.')
                digest = hashlib.sha256(token.encode()).hexdigest()
                db.execute('BEGIN IMMEDIATE')
                existing = db.execute('SELECT token FROM vehicles WHERE vehicle=?', (vehicle,)).fetchone()
                if existing and existing[0] != digest:
                    return 409, {'ok': False, 'error': '다른 기기가 등록한 차량입니다. 차량번호를 확인하세요.'}
                db.execute('INSERT INTO vehicles VALUES (?,?,?) ON CONFLICT(vehicle) DO UPDATE SET route=excluded.route', (vehicle, route, digest))
                return 200, {'ok': True, 'vehicleNo': vehicle, 'routeNo': route}
            if method == 'GET' and path == '/driver/vehicles':
                route = required(body, 'routeNo')
                rows = db.execute('SELECT vehicle, route FROM vehicles WHERE route=? ORDER BY vehicle', (route,)).fetchall()
                return 200, {'ok': True, 'vehicles': [{'vehicleNo': v, 'routeNo': r} for v, r in rows]}
            if method == 'POST' and path == '/driver/inbox':
                vehicle, token = (required(body, k) for k in ('vehicleNo', 'token'))
                digest = hashlib.sha256(token.encode()).hexdigest()
                if not db.execute('SELECT 1 FROM vehicles WHERE vehicle=? AND token=?', (vehicle, digest)).fetchone():
                    return 403, {'ok': False, 'error': '차량 등록 인증에 실패했습니다.'}
                rows = db.execute("SELECT r.payload, r.created, COALESCE(s.state, 'queued') FROM requests r LEFT JOIN request_status s ON r.id=s.id WHERE r.vehicle=? ORDER BY r.created DESC LIMIT 100", (vehicle,)).fetchall()
                return 200, {'ok': True, 'requests': [dict(json.loads(p), createdAt=t, status=state) for p,t,state in rows if not json.loads(p).get('testAllVehicles')]}
            if method == 'POST' and path == '/driver-notifications':
                if body.get('consent') is not True: raise ValueError('승객의 탑승 동의가 필요합니다.')
                data = {k: required(body, k) for k in ('requestId', 'vehicleNo', 'routeNo', 'boardingStop', 'dropoffStop', 'nodeId')}
                data['isTest'] = body.get('isTest') is True
                if body.get('testAllVehicles') is True:
                    if not data['isTest']: raise ValueError('전체 차량 시험은 테스트 요청이어야 합니다.')
                    data['testAllVehicles'] = True
                if body.get('dropoffNodeId'):
                    try:
                        data['dropoffNodeId'] = 'CJB'+local_id(body['dropoffNodeId'])
                    except ValueError:
                        pass  # Preserve missing mapping explicitly; do not guess by name.
                if data.get('testAllVehicles') and body.get('trackingToken'):
                    data['trackingToken'] = required(body, 'trackingToken')
                passenger_token = required(body, 'passengerToken')
                if len(passenger_token) < 32: raise ValueError('승객 인증값이 너무 짧습니다.')
                passenger_hash = hashlib.sha256(passenger_token.encode()).hexdigest()
                if not data['isTest']:
                    data['matchToken'] = required(body, 'matchToken')
                encoded = json.dumps(data, sort_keys=True, ensure_ascii=False)
                db.execute('BEGIN IMMEDIATE')
                old = db.execute('SELECT payload FROM requests WHERE id=?', (data['requestId'],)).fetchone()
                if old:
                    auth = db.execute('SELECT passenger_hash FROM request_status WHERE id=?', (data['requestId'],)).fetchone()
                    if not auth or auth[0] != passenger_hash: return 403, {'ok': False, 'error': '요청 인증값이 다릅니다.'}
                    if old[0] != encoded: return 409, {'ok': False, 'error': '같은 요청 번호의 내용이 다릅니다.'}
                else:
                    match = None
                    if data.get('trackingToken'):
                        record = db.execute('SELECT payload, expires FROM vehicle_matches WHERE token=?', (data['trackingToken'],)).fetchone()
                        if not record or record[1] < time.time():
                            return 409, {'ok': False, 'error': '차량 확인이 만료되었습니다. 테스트 노선을 다시 연결해주세요.'}
                        match = json.loads(record[0])
                        if not match.get('testOnly') or any(data[k] != match[k] for k in ('vehicleNo', 'routeNo', 'nodeId')):
                            return 409, {'ok': False, 'error': '확인된 테스트 차량과 요청 정보가 다릅니다.'}
                    if not data['isTest']:
                        binding = db.execute('SELECT payload, expires FROM vehicle_matches WHERE token=?', (data['matchToken'],)).fetchone()
                        if not binding or binding[1] < time.time():
                            return 409, {'ok': False, 'error': '차량 확인이 만료되었습니다. 차량을 다시 조회해주세요.'}
                        match = json.loads(binding[0])
                        if match.get('testOnly'): return 409, {'ok': False, 'error': '테스트 차량 확인으로 실제 요청을 보낼 수 없습니다.'}
                        if any(data[k] != match[k] for k in ('vehicleNo', 'routeNo', 'nodeId')):
                            return 409, {'ok': False, 'error': '확인된 도착 차량과 요청 정보가 다릅니다.'}
                        latest = resolve_vehicle(match['cityCode'], match['nodeId'], match['routeId'], match['routeNo'])
                        if latest['vehicleId'] != match['vehicleId'] or plate(latest['vehicleNo']) != plate(match['vehicleNo']):
                            return 409, {'ok': False, 'error': '도착 예정 차량이 바뀌었습니다. 다시 조회하고 동의해주세요.'}
                    if not data.get('testAllVehicles') and not db.execute('SELECT 1 FROM vehicles WHERE vehicle=? AND route=?', (data['vehicleNo'], data['routeNo'])).fetchone():
                        return 409, {'ok': False, 'error': '해당 노선으로 등록된 차량이 없습니다.'}
                    db.execute('INSERT INTO requests VALUES (?,?,?,?)', (data['requestId'], data['vehicleNo'], encoded, datetime.now(timezone.utc).isoformat()))
                    if match is not None:
                        tracking = {k: match[k] for k in ('cityCode', 'routeId', 'routeNo', 'nodeId', 'vehicleId', 'vehicleNo')}
                        tracking.update(dropoffNodeId=data.get('dropoffNodeId'), dropoffStop=data['dropoffStop'],
                                        isTest=data['isTest'], boundAt=match['checkedAt'])
                        db.execute('INSERT INTO request_tracking VALUES (?,?)',
                                   (data['requestId'], json.dumps(tracking, ensure_ascii=False)))
                db.execute("INSERT OR IGNORE INTO request_status(id,state,passenger_hash) VALUES (?, 'queued', ?)", (data['requestId'], passenger_hash))
                return 200, {'ok': True, 'status': 'queued', 'requestId': data['requestId']}
            return 405, {'ok': False, 'error': '지원하지 않는 요청 방식입니다.'}
    except (ValueError, TypeError) as error:
        return 400, {'ok': False, 'error': str(error)}
