// C imports for DirectWrite system font fallback on Windows. This is
// translated to Zig with translate-c, so we use the C (not C++) COM
// interfaces: each interface is a struct with an `lpVtbl` pointer to a
// struct of function pointers.
#define CINTERFACE
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <dwrite_2.h>
