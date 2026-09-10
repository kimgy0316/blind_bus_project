"""TAGO location lookup, kept separate from stop arrival predictions."""
import os
from datetime import datetime, timezone
import requests
from search_bus_arrival import get_bus_arrivals, filter_route_arrivals

URL = 'https://apis.data.go.kr/1613000/BusLcInfoInqireService/getRouteAcctoBusLcList'

ROUTE_STATIONS_URL = (
    'https://apis.data.go.kr/1613000/BusRouteInfoInqireService/'
    'getRouteAcctoThrghSttnList'
)

def route_stations(city, route_id):
    key = os.getenv('BUS_LOCATION_API_KEY') or os.getenv('BUS_ARRIVAL_API_KEY')
    if not key:
        raise ValueError('TAGO API 키가 필요합니다.')

    try:
        response = requests.get(
            ROUTE_STATIONS_URL,
            params={
                'serviceKey': key,
                '_type': 'json',
                'cityCode': city,
                'routeId': route_id,
                'numOfRows': 300,
                'pageNo': 1,
            },
            timeout=5,
        )
        response.raise_for_status()
        data = response.json()
    except requests.RequestException as e:
        raise ValueError(f'노선 정류소 API 연결 실패: {e}') from None
    except ValueError:
        raise ValueError('노선 정류소 API 응답을 읽지 못했습니다.') from None

    header = data.get('response', {}).get('header', {})
    code = str(header.get('resultCode', ''))

    if code not in ('00', '0'):
        raise ValueError(
            '노선 정류소 API 응답코드 '
            + code
            + ': '
            + str(header.get('resultMsg', ''))
        )

    body = data.get('response', {}).get('body', {})
    items = (body.get('items') or {}).get('item', [])

    if isinstance(items, dict):
        items = [items]

    return items

def location_items(city, route_id):
    key = os.getenv('BUS_LOCATION_API_KEY') or os.getenv('BUS_ARRIVAL_API_KEY')
    if not key:
        raise ValueError('BUS_LOCATION_API_KEY 또는 BUS_ARRIVAL_API_KEY가 필요합니다.')
    result = []
    for page in range(1, 3):
        try:
            response = requests.get(URL, params={'serviceKey': key, '_type': 'json',
                'cityCode': city, 'routeId': route_id, 'numOfRows': 100, 'pageNo': page}, timeout=3)
            if response.status_code != 200: raise ValueError('위치 API HTTP 오류. 활용승인과 키를 확인하세요.')
            data = response.json()
        except requests.RequestException:
            raise ValueError('위치 API 연결 실패. 잠시 후 다시 조회하세요.') from None
        except ValueError:
            raise ValueError('위치 API 응답을 읽지 못했습니다. 버스위치정보 활용승인과 키를 확인하세요.') from None
        header = data.get('response', {}).get('header', {})
        if str(header.get('resultCode')) not in ('00', '0'):
            raise ValueError('위치 API 응답코드 ' + str(header.get('resultCode')) + '. 버스위치정보 활용승인을 확인하세요.')
        body = data.get('response', {}).get('body', {})
        items = (body.get('items') or {}).get('item', [])
        if isinstance(items, dict): items = [items]
        result.extend(items)
        if len(result) >= int(body.get('totalCount') or 0) or not items: return result
    raise ValueError('위치정보가 조회 범위를 초과했습니다.')

def match_arrival_vehicle(city, node, arrival):
    route_id = str(arrival.get('route_id') or '')
    prev_count = arrival.get('prev_station_count')

    if not route_id or prev_count is None:
        raise ValueError('도착정보에 노선 ID 또는 남은 정류장 수가 없습니다.')

    try:
        prev_count = int(prev_count)
    except (TypeError, ValueError):
        raise ValueError('남은 정류장 수를 확인할 수 없습니다.') from None

    stations = route_stations(city, route_id)

    target_orders = []
    for station in stations:
        if str(station.get('nodeid') or '') == str(node):
            try:
                target_orders.append(int(station.get('nodeord')))
            except (TypeError, ValueError):
                pass

    if len(target_orders) != 1:
        raise ValueError('승차 정류장의 노선 순서를 하나로 확인하지 못했습니다.')

    target_order = target_orders[0]

    candidates = []

    for vehicle in location_items(city, route_id):
        try:
            current_order = int(vehicle.get('nodeord'))
        except (TypeError, ValueError):
            continue

        remaining = target_order - current_order

        if remaining == prev_count:
            vehicle_no = str(vehicle.get('vehicleno') or '').strip()

            if vehicle_no:
                candidates.append({
                    'vehicleNo': vehicle_no,
                    'routeId': route_id,
                    'routeNo': str(arrival.get('route_no') or ''),
                    'nodeId': vehicle.get('nodeid'),
                    'stopName': vehicle.get('nodenm'),
                    'stopOrder': current_order,
                    'latitude': vehicle.get('gpslati'),
                    'longitude': vehicle.get('gpslong'),
                    'remainingStops': remaining,
                    'arrivalSeconds': arrival.get('arrival_seconds'),
                    'arrivalMinutes': arrival.get('arrival_minutes'),
                })

    if len(candidates) != 1:
        raise ValueError(
            f'도착 예정 차량을 하나로 확정하지 못했습니다. 후보 {len(candidates)}대'
        )

    return candidates[0]

def live_info(city, node, route_no):
    try:
        data = get_bus_arrivals(city, node, num_of_rows=100)
    except requests.RequestException:
        raise ValueError(
            '도착정보 API 연결 실패. 키의 활용승인과 네트워크를 확인하세요.'
        ) from None

    code = str(
        data.get('response', {}).get('header', {}).get('resultCode', '')
    )
    if code not in ('00', '0'):
        raise ValueError('도착정보 API 응답코드: ' + code)

    arrivals = [
        a
        for a in filter_route_arrivals(data, [route_no])
        if a['arrival_seconds'] >= 0
    ]

    route_ids = sorted({
        str(a['route_id'])
        for a in arrivals
        if a.get('route_id')
    })

    vehicles = []
    errors = []

    for route_id in route_ids[:4]:
        try:
            for item in location_items(city, route_id):
                vehicles.append({
                    'vehicleNo': str(item.get('vehicleno') or ''),
                    'routeId': route_id,
                    'routeNo': str(item.get('routenm') or route_no),
                    'nodeId': item.get('nodeid'),
                    'stopName': item.get('nodenm'),
                    'stopOrder': item.get('nodeord'),
                    'latitude': item.get('gpslati'),
                    'longitude': item.get('gpslong'),
                })
        except ValueError as error:
            errors.append(str(error))

    matched_vehicle = None
    match_error = None

    if arrivals:
        try:
            matched_vehicle = match_arrival_vehicle(
                city,
                node,
                arrivals[0],
            )
        except ValueError as error:
            match_error = str(error)

    return {
        'ok': True,
        'cityCode': city,
        'nodeId': node,
        'routeNo': route_no,
        'checkedAt': datetime.now(timezone.utc).isoformat(),

        'arrivals': [
            {k: v for k, v in a.items() if k != 'raw'}
            for a in arrivals
        ],

        'vehicles': vehicles,
        'locationErrors': errors,

        'matchedVehicle': matched_vehicle,
        'vehicleArrivalLinked': matched_vehicle is not None,

        'message': (
            '도착 예정 버스와 실제 운행 차량을 연결했습니다.'
            if matched_vehicle is not None
            else (
                match_error
                or '현재 도착 예정 차량을 확인할 수 없습니다.'
            )
        ),
    }