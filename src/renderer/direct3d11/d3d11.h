// C imports for the Direct3D 11 renderer. This is translated to Zig with
// translate-c, so we use the C (not C++) COM interfaces: each interface is
// a struct with an `lpVtbl` pointer to a struct of function pointers.
#define CINTERFACE
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
