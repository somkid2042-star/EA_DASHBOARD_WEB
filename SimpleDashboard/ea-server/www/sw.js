self.addEventListener('push', function (event) {
    if (event.data) {
        try {
            const data = event.data.json();
            const title = data.title || 'EA Notification';
            const options = {
                body: data.body,
                icon: data.icon || '/icon.png', // Fallback icon
                badge: '/icon.png',
                vibrate: [200, 100, 200, 100, 200, 100, 200],
                data: {
                    dateOfArrival: Date.now(),
                    primaryKey: 1
                }
            };
            event.waitUntil(self.registration.showNotification(title, options));
        } catch (e) {
            console.error('[SW] Error parsing push data', e);
            event.waitUntil(self.registration.showNotification('EA Update', {
                body: event.data.text()
            }));
        }
    }
});

self.addEventListener('notificationclick', function (event) {
    event.notification.close();
    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clientList) {
            if (clientList.length > 0) {
                let client = clientList[0];
                for (let i = 0; i < clientList.length; i++) {
                    if (clientList[i].focused) {
                        client = clientList[i];
                    }
                }
                return client.focus();
            }
            return clients.openWindow('/');
        })
    );
});
