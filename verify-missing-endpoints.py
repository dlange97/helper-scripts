#!/usr/bin/env python3
import json
import time
import urllib.error
import urllib.request

BASE = 'http://localhost:8081'
ADMIN_EMAIL = 'admin.test@micro.com'
ADMIN_PASSWORD = 'Admin123!'
INTERNAL_TOKEN = 'internal_notification_token_change_me'
EMAIL = f'ui-check-{int(time.time())}@example.com'


def call(method, path, payload=None, token=None, extra_headers=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    if extra_headers:
        headers.update(extra_headers)

    data = None if payload is None else json.dumps(payload).encode('utf-8')
    request = urllib.request.Request(
        f'{BASE}{path}',
        data=data,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(request) as response:
            body = response.read().decode('utf-8')
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode('utf-8')
        try:
            parsed = json.loads(body) if body else None
        except json.JSONDecodeError:
            parsed = body
        return exc.code, parsed


def check(name, actual, expected):
    if actual != expected:
        raise SystemExit(f'FAIL {name}: expected {expected}, got {actual}')

    print(f'OK {name}: {actual}')


status, body = call('POST', '/auth/login', {
    'email': ADMIN_EMAIL,
    'password': ADMIN_PASSWORD,
})
check('login-bootstrap', status, 200)
TOKEN = body['token']

status, _ = call('GET', '/dashboard/health')
check('dashboard-health', status, 200)
status, _ = call('POST', '/auth/validate', {}, token=TOKEN)
check('auth-validate', status, 200)
status, _ = call('GET', '/auth/users', token=TOKEN)
check('users-list', status, 200)

status, body = call('POST', '/auth/users', {
    'email': EMAIL,
    'password': 'Admin123!',
    'firstName': 'Ui',
    'lastName': 'Check',
    'role': 'ROLE_USER',
}, token=TOKEN)
check('users-create', status, 201)
user_id = body['user']['id']

status, _ = call('PATCH', f'/auth/users/{user_id}/role', {
    'role': 'ROLE_ADMIN',
}, token=TOKEN)
check('users-assign-role', status, 200)

status, _ = call('GET', '/dashboard/todos', token=TOKEN)
check('todos-index', status, 200)
status, _ = call('GET', '/dashboard/shopping-lists', token=TOKEN)
check('shopping-index', status, 200)

status, body = call('POST', '/dashboard/shopping-lists', {
    'name': 'UI Verify List',
    'products': [],
}, token=TOKEN)
check('shopping-create-2', status, 201)
list_id = body['id']

status, _ = call('GET', f'/dashboard/shopping-lists/{list_id}', token=TOKEN)
check('shopping-show', status, 200)
status, body = call('POST', f'/dashboard/shopping-lists/{list_id}/products', {
    'name': 'Water',
    'qty': 1,
}, token=TOKEN)
check('shopping-add-product', status, 201)
product_id = body['id']

status, _ = call('DELETE', f'/dashboard/shopping-lists/{list_id}/products/{product_id}', token=TOKEN)
check('shopping-remove-product', status, 204)
status, _ = call('DELETE', f'/dashboard/shopping-lists/{list_id}', token=TOKEN)
check('shopping-delete-2', status, 204)

status, _ = call('GET', '/events', token=TOKEN)
check('events-index', status, 200)
status, body = call('POST', '/events', {
    'title': 'User page verify event',
    'description': 'detail route test',
    'startAt': '2030-01-10T12:00:00+00:00',
    'endAt': '2030-01-10T14:00:00+00:00',
    'location': {
        'display_name': 'Warsaw',
        'lat': 52.2297,
        'lon': 21.0122,
    },
}, token=TOKEN)
check('event-create-2', status, 201)
event_id = body['id']

status, _ = call('GET', f'/events/{event_id}', token=TOKEN)
check('event-show', status, 200)
status, _ = call('DELETE', f'/events/{event_id}', token=TOKEN)
check('event-delete-2', status, 204)

status, body = call('POST', '/notification/inbox', {
    'recipientEmail': EMAIL,
    'type': 'manual-check',
    'title': 'Manual notification',
    'body': 'Created during verification',
}, token=TOKEN)
check('notification-create', status, 201)
notification_id = body['id']

status, _ = call('PUT', f'/notification/inbox/{notification_id}', {
    'title': 'Manual notification updated',
    'body': 'Updated during verification',
}, token=TOKEN)
check('notification-update', status, 200)
status, _ = call('PATCH', f'/notification/inbox/{notification_id}/read', {}, token=TOKEN)
check('notification-mark-read', status, 200)
status, _ = call('DELETE', f'/notification/inbox/{notification_id}', token=TOKEN)
check('notification-delete', status, 204)

status, _ = call('POST', '/notification/internal/request-access', {
    'requester': {
        'email': 'requester@example.com',
        'firstName': 'Req',
        'lastName': 'Tester',
        'message': 'hello',
    },
    'recipients': [
        {'id': user_id, 'email': EMAIL},
    ],
}, extra_headers={'X-Internal-Token': INTERNAL_TOKEN})
check('notification-internal-request-access', status, 201)

print('SUPPLEMENTAL_ENDPOINTS_OK')
