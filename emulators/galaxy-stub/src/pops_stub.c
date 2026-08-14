/* pops_api.dll — benign no-ops for the older GOG "POPS" online-services client.
 *
 * Win64 has a single calling convention, so these (void) signatures are ABI-safe regardless of the real
 * prototypes: the caller passes args in registers and cleans up, and the callee may ignore them. Init
 * returns 0 ("no error"); the account/telemetry/legal calls report nothing; RunCallbacks/Shutdown do
 * nothing. No network is ever touched.
 */
__declspec(dllexport) int POPS_Initialize(void) { return 0; }
__declspec(dllexport) void POPS_Shutdown(void) {}
__declspec(dllexport) void POPS_RunCallbacks(void) {}
__declspec(dllexport) int POPS_AccountLogInWithAuthToken(void) { return 0; }
__declspec(dllexport) void POPS_AutoStandardTelemetryEnable(void) {}
__declspec(dllexport) int POPS_LegalGetDocument(void) { return 0; }
__declspec(dllexport) int POPS_LegalGetDocumentsList(void) { return 0; }
__declspec(dllexport) void POPS_GenerateGUID(void) {}
