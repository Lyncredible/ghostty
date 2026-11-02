// A UI Automation client for uia-events.ps1, using the native COM API
// that screen readers use. It listens on a surface (and the window
// holding it) and prints one line per event:
//
//     ready
//     selection
//     notification:<text>
//     tab:<name>
//
// Build:  zig cc -target x86_64-windows-gnu uia_events.c -o uia-events.exe -lole32 -loleaut32 -luuid
// Usage:  uia-events.exe <surface hwnd> <seconds>

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <uiautomation.h>
#include <stdio.h>
#include <stdlib.h>

static void print_bstr(const char *prefix, BSTR text) {
    char buf[4096];
    int n = text ? WideCharToMultiByte(CP_UTF8, 0, text, -1, buf, sizeof(buf), NULL, NULL) : 0;
    if (n <= 0) buf[0] = 0;
    for (char *p = buf; *p; p++) if (*p == '\r' || *p == '\n') *p = ' ';
    printf("%s%s\n", prefix, buf);
    fflush(stdout);
}

// Handlers live for the whole program, so reference counting is a no-op.
#define UNKNOWN_METHODS(name, Type, iid)                                                  \
    static HRESULT STDMETHODCALLTYPE name##_query(Type *self, REFIID riid, void **out) {  \
        if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, iid)) {                   \
            *out = self;                                                                  \
            return S_OK;                                                                  \
        }                                                                                 \
        *out = NULL;                                                                      \
        return E_NOINTERFACE;                                                             \
    }                                                                                     \
    static ULONG STDMETHODCALLTYPE name##_add_ref(Type *self) { (void)self; return 1; }   \
    static ULONG STDMETHODCALLTYPE name##_release(Type *self) { (void)self; return 1; }

UNKNOWN_METHODS(event, IUIAutomationEventHandler, &IID_IUIAutomationEventHandler)
UNKNOWN_METHODS(notification, IUIAutomationNotificationEventHandler, &IID_IUIAutomationNotificationEventHandler)

static HRESULT STDMETHODCALLTYPE handle_event(IUIAutomationEventHandler *self, IUIAutomationElement *sender, EVENTID id) {
    (void)self;
    if (id == UIA_Text_TextSelectionChangedEventId) {
        printf("selection\n");
        fflush(stdout);
    } else if (id == UIA_SelectionItem_ElementSelectedEventId) {
        BSTR name = NULL;
        IUIAutomationElement_get_CurrentName(sender, &name);
        print_bstr("tab:", name);
        SysFreeString(name);
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE handle_notification(
    IUIAutomationNotificationEventHandler *self, IUIAutomationElement *sender,
    enum NotificationKind kind, enum NotificationProcessing processing, BSTR text, BSTR activity) {
    (void)self; (void)sender; (void)kind; (void)processing; (void)activity;
    print_bstr("notification:", text);
    return S_OK;
}

static IUIAutomationEventHandlerVtbl event_vtbl = {
    event_query, event_add_ref, event_release, handle_event,
};
static IUIAutomationNotificationEventHandlerVtbl notification_vtbl = {
    notification_query, notification_add_ref, notification_release, handle_notification,
};
static IUIAutomationEventHandler event_handler = { &event_vtbl };
static IUIAutomationNotificationEventHandler notification_handler = { &notification_vtbl };

static int check(HRESULT hr, const char *what) {
    if (FAILED(hr)) {
        printf("error:%s hr=0x%08lx\n", what, (unsigned long)hr);
        fflush(stdout);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: uia-events <surface hwnd> <seconds>\n");
        return 2;
    }
    HWND surface_hwnd = (HWND)(UINT_PTR)_strtoui64(argv[1], NULL, 0);
    int seconds = atoi(argv[2]);

    // In the MTA, events arrive on UI Automation's threads without a
    // message loop here.
    if (!check(CoInitializeEx(NULL, COINIT_MULTITHREADED), "CoInitializeEx")) return 1;
    IUIAutomation5 *uia = NULL;
    if (!check(CoCreateInstance(&CLSID_CUIAutomation8, NULL, CLSCTX_INPROC_SERVER, &IID_IUIAutomation5, (void **)&uia),
               "CoCreateInstance")) return 1;

    IUIAutomationElement *surface = NULL, *window = NULL;
    if (!check(IUIAutomation5_ElementFromHandle(uia, surface_hwnd, &surface), "ElementFromHandle surface")) return 1;
    if (!check(IUIAutomation5_ElementFromHandle(uia, GetAncestor(surface_hwnd, GA_ROOT), &window), "ElementFromHandle window")) return 1;

    if (!check(IUIAutomation5_AddAutomationEventHandler(uia, UIA_Text_TextSelectionChangedEventId, surface,
                                                        TreeScope_Element, NULL, &event_handler), "selection handler")) return 1;
    if (!check(IUIAutomation5_AddAutomationEventHandler(uia, UIA_SelectionItem_ElementSelectedEventId, window,
                                                        TreeScope_Subtree, NULL, &event_handler), "tab handler")) return 1;
    if (!check(IUIAutomation5_AddNotificationEventHandler(uia, surface, TreeScope_Element, NULL, &notification_handler),
               "notification handler")) return 1;

    printf("ready\n");
    fflush(stdout);
    Sleep((DWORD)seconds * 1000);

    IUIAutomation5_RemoveAllEventHandlers(uia);
    IUIAutomationElement_Release(surface);
    IUIAutomationElement_Release(window);
    IUIAutomation5_Release(uia);
    CoUninitialize();
    return 0;
}
