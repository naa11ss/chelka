//
//  Объявления приватного API системы событий HID.
//
//  Публичного способа прочитать температуру на Apple Silicon нет: ключи SMC,
//  работавшие на Intel, для M-серии не отдаются. Единственный рабочий путь —
//  IOHIDEventSystemClient, который системой не документирован, но стабильно
//  используется всеми мониторами (Stats, iStat Menus, TG Pro) и не требует
//  ни root, ни особых прав.
//
//  Здесь только объявления: сами символы живут в IOKit.framework.
//  Приложение обязано пережить их исчезновение — вызывающая сторона
//  проверяет каждый результат и умеет работать без датчиков.
//

#ifndef CIOKIT_SHIM_H
#define CIOKIT_SHIM_H

#include <CoreFoundation/CoreFoundation.h>

typedef struct __IOHIDEvent *ChelkaIOHIDEventRef;
typedef struct __IOHIDServiceClient *ChelkaIOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *ChelkaIOHIDEventSystemClientRef;

/// Тип события «температура» в системе HID.
#define CHELKA_IOHID_EVENT_TYPE_TEMPERATURE 15

/// Поле значения для события температуры: тип, сдвинутый в старшие разряды.
#define CHELKA_IOHID_FIELD_TEMPERATURE (CHELKA_IOHID_EVENT_TYPE_TEMPERATURE << 16)

/// Страница и назначение, под которыми публикуются термодатчики Apple Silicon.
#define CHELKA_SENSOR_USAGE_PAGE 0xff00
#define CHELKA_SENSOR_USAGE_TEMPERATURE 5

extern ChelkaIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(ChelkaIOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(ChelkaIOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(ChelkaIOHIDServiceClientRef service, CFStringRef property);
extern ChelkaIOHIDEventRef IOHIDServiceClientCopyEvent(
    ChelkaIOHIDServiceClientRef service,
    int64_t type,
    int32_t options,
    int64_t timestamp
);
extern double IOHIDEventGetFloatValue(ChelkaIOHIDEventRef event, int32_t field);

#endif /* CIOKIT_SHIM_H */
