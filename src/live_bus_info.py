"""TAGO location lookup, kept separate from stop arrival predictions."""
import os
from datetime import datetime, timezone
import requests
from search_bus_arrival import get_bus_arrivals, filter_route_arrivals

URL = 'https://apis.data.go.kr/1613000/BusLcInfoInqireService/getRouteAcctoBusLcList'

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

def live_info(city, node, route_no):
    try:
        data = get_bus_arrivals(city, node, num_of_rows=100)
    except requests.RequestException:
        raise ValueError('도착정보 API 연결 실패. 키의 활용승인과 네트워크를 확인하세요.') from None
    code = str(data.get('response', {}).get('header', {}).get('resultCode', ''))
    if code not in ('00', '0'): raise ValueError('도착정보 API 응답코드: ' + code)
    arrivals = [a for a in filter_route_arrivals(data, [route_no]) if a['arrival_seconds'] >= 0]
    route_ids = sorted({str(a['route_id']) for a in arrivals if a.get('route_id')})
    vehicles, errors = [], []
    for route_id in route_ids[:4]:
        try:
            for item in location_items(city, route_id):
                vehicles.append({'vehicleNo': str(item.get('vehicleno') or ''),
                    'routeId': route_id, 'routeNo': str(item.get('routenm') or route_no),
                    'nodeId': item.get('nodeid'), 'stopName': item.get('nodenm'),
                    'stopOrder': item.get('nodeord'), 'latitude': item.get('gpslati'),
                    'longitude': item.get('gpslong')})
        except ValueError as error: errors.append(str(error))
    return {'ok': True, 'cityCode': city, 'nodeId': node, 'routeNo': route_no,
        'checkedAt': datetime.now(timezone.utc).isoformat(),
        'arrivals': [{k:v for k,v in a.items() if k != 'raw'} for a in arrivals],
        'vehicles': vehicles, 'locationErrors': errors,
        'vehicleArrivalLinked': False,
        'message': '노선 도착시간과 운행 차량 목록은 별도 정보입니다. 어떤 차량이 몇 분 뒤 도착하는지는 확인되지 않았습니다.'}
