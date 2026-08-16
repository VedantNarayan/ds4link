#define INITGUID
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#define DIRECTINPUT_VERSION 0x0800
#include <dinput.h>
#include <stdio.h>

#pragma comment(lib, "ws2_32.lib")

static HMODULE hOrigDInputDll = NULL;
typedef HRESULT (WINAPI *DirectInput8Create_t)(HINSTANCE, DWORD, REFIID, LPVOID*, LPUNKNOWN);
static DirectInput8Create_t orig_DirectInput8Create = NULL;

static void LoadOriginalDll() {
    if (hOrigDInputDll) return;
    char sysDir[MAX_PATH];
    GetSystemDirectoryA(sysDir, MAX_PATH);
    char dllPath[MAX_PATH];
    snprintf(dllPath, sizeof(dllPath), "%s\\dinput8.dll", sysDir);
    hOrigDInputDll = LoadLibraryA(dllPath);
    if (hOrigDInputDll) {
        orig_DirectInput8Create = (DirectInput8Create_t)GetProcAddress(hOrigDInputDll, "DirectInput8Create");
    }
}

// Wrapper for IDirectInput8W to filter out raw Sony devices and force games to use XInput
class WrappedDirectInput8W : public IDirectInput8W {
public:
    IDirectInput8W* m_pOrig;
    LONG m_refCount;

    WrappedDirectInput8W(IDirectInput8W* pOrig) : m_pOrig(pOrig), m_refCount(1) {}

    /*** IUnknown methods ***/
    STDMETHOD(QueryInterface)(REFIID riid, LPVOID* ppvObj) {
        return m_pOrig->QueryInterface(riid, ppvObj);
    }
    STDMETHOD_(ULONG, AddRef)() {
        return InterlockedIncrement(&m_refCount);
    }
    STDMETHOD_(ULONG, Release)() {
        ULONG count = InterlockedDecrement(&m_refCount);
        if (count == 0) {
            m_pOrig->Release();
            delete this;
            return 0;
        }
        return count;
    }

    /*** IDirectInput8W methods ***/
    STDMETHOD(CreateDevice)(REFGUID rguid, LPDIRECTINPUTDEVICE8W* lplpDirectInputDevice, LPUNKNOWN pUnkOuter) {
        return m_pOrig->CreateDevice(rguid, lplpDirectInputDevice, pUnkOuter);
    }

    // Intercept EnumDevices: Return DI_OK with 0 devices to force games to use standard XInput
    STDMETHOD(EnumDevices)(DWORD dwDevType, LPDIENUMDEVICESCALLBACKW lpCallback, LPVOID pvRef, DWORD dwFlags) {
        // Suppress DirectInput joystick enumeration so games don't try to use broken LibScePad raw HID
        if (dwDevType == DI8DEVCLASS_GAMECTRL || dwDevType == DI8DEVCLASS_ALL || dwDevType == 0) {
            return DI_OK; // Return 0 devices
        }
        return m_pOrig->EnumDevices(dwDevType, lpCallback, pvRef, dwFlags);
    }

    STDMETHOD(GetDeviceStatus)(REFGUID rguid) {
        return m_pOrig->GetDeviceStatus(rguid);
    }
    STDMETHOD(RunControlPanel)(HWND hwndOwner, DWORD dwFlags) {
        return m_pOrig->RunControlPanel(hwndOwner, dwFlags);
    }
    STDMETHOD(Initialize)(HINSTANCE hinst, DWORD dwVersion) {
        return m_pOrig->Initialize(hinst, dwVersion);
    }
    STDMETHOD(FindDevice)(REFGUID rguidClass, LPCWSTR pwszName, LPGUID pguidInstance) {
        return m_pOrig->FindDevice(rguidClass, pwszName, pguidInstance);
    }
    STDMETHOD(EnumDevicesBySemantics)(LPCWSTR pwszUserName, LPDIACTIONFORMATW lpdiActionFormat, LPDIENUMDEVICESBYSEMANTICSCBW lpCallback, LPVOID pvRef, DWORD dwFlags) {
        return DI_OK;
    }
    STDMETHOD(ConfigureDevices)(LPDICONFIGUREDEVICESCALLBACK lpdiCallback, LPDICONFIGUREDEVICESPARAMSW lpdiCDParams, DWORD dwFlags, LPVOID pvRef) {
        return m_pOrig->ConfigureDevices(lpdiCallback, lpdiCDParams, dwFlags, pvRef);
    }
};

extern "C" {

__declspec(dllexport) HRESULT WINAPI DirectInput8Create(HINSTANCE hinst, DWORD dwVersion, REFIID riidltf, LPVOID* ppvOut, LPUNKNOWN punkOuter) {
    LoadOriginalDll();
    if (orig_DirectInput8Create) {
        HRESULT hr = orig_DirectInput8Create(hinst, dwVersion, riidltf, ppvOut, punkOuter);
        if (SUCCEEDED(hr) && ppvOut && *ppvOut) {
            if (IsEqualIID(riidltf, IID_IDirectInput8W)) {
                IDirectInput8W* pOrig = (IDirectInput8W*)*ppvOut;
                *ppvOut = new WrappedDirectInput8W(pOrig);
            }
        }
        return hr;
    }
    return DIERR_NOTINITIALIZED;
}

__declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(void) {
    return S_OK;
}

__declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, LPVOID* ppv) {
    LoadOriginalDll();
    typedef HRESULT (WINAPI *DllGetClassObject_t)(REFCLSID, REFIID, LPVOID*);
    DllGetClassObject_t orig = (DllGetClassObject_t)GetProcAddress(hOrigDInputDll, "DllGetClassObject");
    if (orig) return orig(rclsid, riid, ppv);
    return CLASS_E_CLASSNOTAVAILABLE;
}

__declspec(dllexport) HRESULT WINAPI DllRegisterServer(void) {
    return S_OK;
}

__declspec(dllexport) HRESULT WINAPI DllUnregisterServer(void) {
    return S_OK;
}

__declspec(dllexport) BOOL WINAPI DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved) {
    if (ul_reason_for_call == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hModule);
    }
    return TRUE;
}

}
