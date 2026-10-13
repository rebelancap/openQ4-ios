/*
 * volk.h — iOS shim replacing the volk meta-loader (DECISIONS D-013).
 *
 * WHY THIS EXISTS
 *
 * openQ4's Vulkan renderer calls Vulkan through volk, which declares its
 * function pointers as globals named exactly like the Vulkan entry points
 * (`PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;`). On iOS, MoltenVK is
 * linked STATICALLY and exports real functions of those same names. In one flat
 * symbol namespace the two cannot coexist:
 *
 *   as-is:        the linker merges volk's pointer into MoltenVK's function and
 *                 volk then loads through it as data —
 *                 "ld: fixup error (kind=arm64_lo12) at '_volkInitialize'+0xAC,
 *                  target '_vkGetInstanceProcAddr' not 8-byte aligned"
 *   -fno-common:  414 honest duplicate symbols
 *
 * Neither side can yield. SDL locates static MoltenVK with
 * dlsym(RTLD_DEFAULT, "vkGetInstanceProcAddr"), so MoltenVK must own that name.
 *
 * The resolution is to remove the meta-loader instead: with MoltenVK linked in,
 * every entry point already resolves directly, so a loader has nothing to do.
 * This header is placed earlier in the include path than src/external/volk, and
 * every `#include "volk.h"` site resolves here instead. No upstream file is
 * edited, and volk.c is simply not compiled on iOS.
 *
 * WHY THIS IS SAFE (measured, not assumed)
 *
 *   - openQ4 uses exactly four volk entry points — volkInitialize,
 *     volkInitializeCustom, volkLoadInstance, volkLoadDevice — all of which are
 *     pure no-ops once symbols resolve directly.
 *   - It never uses VolkDeviceTable / volkLoadDeviceTable, so no per-device
 *     dispatch optimisation is lost. (Zero hits across the whole tree.)
 *   - All 97 distinct vk* entry points the renderer calls are present in the
 *     shipped MoltenVK ios-arm64 archive (which exports 545).
 *   - VMA is already loader-agnostic here (VMA_STATIC_VULKAN_FUNCTIONS=0,
 *     VMA_DYNAMIC_VULKAN_FUNCTIONS=1) and is fed vkGetInstanceProcAddr /
 *     vkGetDeviceProcAddr explicitly — under this shim those are MoltenVK's real
 *     functions, which is exactly what VMA wants.
 *
 * The macOS oracle keeps using real volk, so it stays bit-identical to upstream.
 */

#ifndef OPENQ4_IOS_VOLK_SHIM_H_
#define OPENQ4_IOS_VOLK_SHIM_H_

/*
 * Deliberately WITHOUT VK_NO_PROTOTYPES: we want the real prototypes so calls
 * bind directly to MoltenVK's statically linked functions.
 */
#include <vulkan/vulkan.h>

/*
 * Entry points the static MoltenVK archive does NOT export as global symbols
 * (it has them, but local), so a direct call or a `!= NULL` test cannot bind at
 * link time. Each is renamed to a pointer that volkLoadInstance resolves through
 * vkGetInstanceProcAddr, exactly as real volk would. C++17 `inline` keeps one
 * definition across the translation units that include this header.
 *
 *   vkGetPhysicalDeviceMultisamplePropertiesEXT  v0.14 sample-locations probe
 *                                                (VulkanDevice.cpp, D-116)
 */
/*
 * D-077's armed main scope, enforced at the draw itself (D-116).
 *
 * Our overlay (0019, D-075/D-077) makes a render-target switch ARM the main
 * scope instead of opening it; the first draw or clear must open it through
 * VK_Exec_EnsureMainScope(). Upstream's own code assumes the eager open, and
 * v0.14 added many draw sites that record straight after
 * VK_Exec_SetRenderTarget (temporal/spatial scene composite, post-process,
 * HDR, scene effects). A draw recorded while the scope is still only armed
 * is a draw outside any render pass: MoltenVK faults on it only at submit
 * (EXC_BAD_ACCESS at 0x128 in MVKRenderSubpass::populateMTLRenderPassDescriptor),
 * which the Arena's first q4dm1 frame hit. Rather than chase every upstream
 * site per pin, every draw and attachment clear opens an armed scope first.
 * VK_Exec_EnsureMainScope is a no-op unless the scope is armed, and it is
 * called only when no dynamic-rendering scope is open on this thread (tracked
 * by wrapping vkCmdBeginRendering/vkCmdEndRendering), so it can never nest a
 * pass inside another — a draw inside any open pass is left exactly as is.
 */
#ifdef __cplusplus
void VK_Exec_EnsureMainScope( void );
inline thread_local int openq4_ios_renderingDepth = 0;
static inline void openq4_ios_vkCmdBeginRendering(VkCommandBuffer c, const VkRenderingInfo *i) {
	vkCmdBeginRendering(c, i); openq4_ios_renderingDepth++;
}
static inline void openq4_ios_vkCmdEndRendering(VkCommandBuffer c) {
	vkCmdEndRendering(c); if (openq4_ios_renderingDepth > 0) { openq4_ios_renderingDepth--; }
}
static inline void openq4_ios_EnsureScopeForDraw(void) {
	if (openq4_ios_renderingDepth == 0) { VK_Exec_EnsureMainScope(); }
}
static inline void openq4_ios_vkCmdDraw(VkCommandBuffer c, uint32_t vc, uint32_t ic, uint32_t fv, uint32_t fi) {
	openq4_ios_EnsureScopeForDraw(); vkCmdDraw(c, vc, ic, fv, fi);
}
static inline void openq4_ios_vkCmdDrawIndexed(VkCommandBuffer c, uint32_t xc, uint32_t ic, uint32_t fx, int32_t vo, uint32_t fi) {
	openq4_ios_EnsureScopeForDraw(); vkCmdDrawIndexed(c, xc, ic, fx, vo, fi);
}
static inline void openq4_ios_vkCmdDrawIndirect(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, uint32_t n, uint32_t st) {
	openq4_ios_EnsureScopeForDraw(); vkCmdDrawIndirect(c, b, o, n, st);
}
static inline void openq4_ios_vkCmdDrawIndexedIndirect(VkCommandBuffer c, VkBuffer b, VkDeviceSize o, uint32_t n, uint32_t st) {
	openq4_ios_EnsureScopeForDraw(); vkCmdDrawIndexedIndirect(c, b, o, n, st);
}
static inline void openq4_ios_vkCmdClearAttachments(VkCommandBuffer c, uint32_t ac, const VkClearAttachment *a, uint32_t rc, const VkClearRect *r) {
	openq4_ios_EnsureScopeForDraw(); vkCmdClearAttachments(c, ac, a, rc, r);
}
#define vkCmdBeginRendering openq4_ios_vkCmdBeginRendering
#define vkCmdEndRendering openq4_ios_vkCmdEndRendering
#define vkCmdDraw openq4_ios_vkCmdDraw
#define vkCmdDrawIndexed openq4_ios_vkCmdDrawIndexed
#define vkCmdDrawIndirect openq4_ios_vkCmdDrawIndirect
#define vkCmdDrawIndexedIndirect openq4_ios_vkCmdDrawIndexedIndirect
#define vkCmdClearAttachments openq4_ios_vkCmdClearAttachments
#endif

#ifdef __cplusplus
inline PFN_vkGetPhysicalDeviceMultisamplePropertiesEXT openq4_ios_vkGetPhysicalDeviceMultisamplePropertiesEXT = nullptr;
#define vkGetPhysicalDeviceMultisamplePropertiesEXT openq4_ios_vkGetPhysicalDeviceMultisamplePropertiesEXT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The four volk entry points openQ4 calls. Each is a no-op: there is nothing to
 * load, because the entry points are already bound at link time.
 *
 * volkInitializeCustom is only reached from the macOS dlopen ladder in
 * VulkanDevice.cpp, which is #if defined(MACOS_X) — it is kept here so the
 * signature exists if that gating ever changes.
 */
static inline VkResult volkInitialize(void) {
	return VK_SUCCESS;
}

static inline void volkInitializeCustom(PFN_vkGetInstanceProcAddr handler) {
	(void)handler;
}

static inline void volkLoadInstance(VkInstance instance) {
#ifdef __cplusplus
	openq4_ios_vkGetPhysicalDeviceMultisamplePropertiesEXT =
		(PFN_vkGetPhysicalDeviceMultisamplePropertiesEXT)vkGetInstanceProcAddr(instance, "vkGetPhysicalDeviceMultisamplePropertiesEXT");
#else
	(void)instance;
#endif
}

static inline void volkLoadInstanceOnly(VkInstance instance) {
	(void)instance;
}

static inline void volkLoadDevice(VkDevice device) {
	(void)device;
}

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_VOLK_SHIM_H_ */
