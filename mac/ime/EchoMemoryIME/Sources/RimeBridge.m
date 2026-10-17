#import "RimeBridge.h"
#include "rime_api.h"
#include <string.h>
static RimeApi *api;
// stringWithUTF8String: returns nil on invalid UTF-8, which crashed addObject: and silently dropped commits.
// Keep the valid characters and mark each undecodable byte with U+FFFD instead. NULL stays nil.
static NSString *ERString(const char *text) {
    if(!text) return nil;
    size_t length = strlen(text);
    NSString *string = [[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
    if(string) return string;
    NSMutableString *lossy = [NSMutableString stringWithCapacity:length];
    for(size_t i=0;i<length;) {
        NSString *piece = nil; size_t n = 0;
        while(!piece && n<4 && i+n<length) piece = [[NSString alloc] initWithBytes:text+i length:++n encoding:NSUTF8StringEncoding];
        if(piece) { [lossy appendString:piece]; i += n; } else { [lossy appendString:@"\uFFFD"]; i++; }
    }
    return lossy;
}
BOOL ERInitialize(NSString *shared, NSString *user) {
    api = rime_get_api();
    if(!api) return NO;
    RIME_STRUCT(RimeTraits, traits);
    // librime copies both paths into its deployer during setup/initialize, so the copies are freed afterwards.
    char *sharedDir = strdup(shared.UTF8String), *userDir = strdup(user.UTF8String);
    traits.shared_data_dir = sharedDir;
    traits.user_data_dir = userDir;
  traits.distribution_name = "APT 输入法";
    traits.distribution_code_name = "echo-memory";
    traits.distribution_version = "0.2";
    traits.app_name = "rime.echo-memory";
    traits.min_log_level = 2;
    traits.log_dir = "";
    api->setup(&traits); api->initialize(&traits);
    free(sharedDir); free(userDir);
    if (api->start_maintenance(True)) api->join_maintenance_thread();
    return YES;
}
uintptr_t ERCreate(void) {
    RimeSessionId s = api->create_session();
    if(!s) return 0;
    api->select_schema(s,"luna_pinyin_simp");
    api->set_option(s,"ascii_mode",False);
    return s;
}
void ERDestroy(uintptr_t s) { if(s) api->destroy_session(s); }
// Rime commits only the input before its caret, so letters behind a ← edit would be lost.
static void ERCaretToEnd(uintptr_t s) { const char *input = api->get_input(s); if(input) api->set_caret_pos(s,strlen(input)); }
BOOL ERProcess(uintptr_t s,int key,int mods) {
    if(key == 0xff0d || key == 0xff8d) ERCaretToEnd(s);  // Return / keypad Enter commit the letters
    return api->process_key(s,key,mods);
}
void ERCommit(uintptr_t s) { ERCaretToEnd(s); api->commit_composition(s); }
// Mainstream IMEs commit the typed letters when Shift switches to English.
// A Shift_L tap makes Rime do exactly that (ascii_composer/switch_key: commit_code);
// Echo tracks the mode itself, so Rime's ascii_mode is reset afterwards.
void ERCommitRaw(uintptr_t s) {
    ERCaretToEnd(s);
    api->process_key(s,0xffe1,0); api->process_key(s,0xffe1,1<<30);
    api->set_option(s,"ascii_mode",False);
    // If commit_code is not in effect nothing was committed; never strand the composition.
    const char *input = api->get_input(s); if(input && *input) api->commit_composition(s);
}
void ERClear(uintptr_t s) { api->clear_composition(s); }
// The input controller resets the mode before every key. librime rebuilds the candidate menu on any
// set_option, even an unchanged one, which sent PageDown / = / ↓ back to page 1 and stopped paging at
// page 2. Only a real change is passed on.
void ERSetASCII(uintptr_t s, BOOL enabled) { if(!api->get_option(s,"ascii_mode") != !enabled) api->set_option(s,"ascii_mode",enabled); }
BOOL ERSelect(uintptr_t s,int index) { return api->select_candidate_on_current_page(s,index); }
NSDictionary *ERSnapshot(uintptr_t s) {
    NSMutableDictionary *result = [@{@"preedit":@"",@"candidates":@[],@"commit":@"",@"cursor":@0} mutableCopy];
    RIME_STRUCT(RimeCommit, commit);
    if(api->get_commit(s,&commit)) {
        if(commit.text) result[@"commit"] = ERString(commit.text);
        api->free_commit(&commit);
    }
    RIME_STRUCT(RimeContext, context);
    if(api->get_context(s,&context)) {
        if(context.composition.preedit) {
            result[@"preedit"] = ERString(context.composition.preedit);
            // Rime reports the caret in UTF-8 bytes; AppKit ranges are UTF-16.
            NSString *head = [[NSString alloc] initWithBytes:context.composition.preedit length:MIN(strlen(context.composition.preedit),(size_t)MAX(0,context.composition.cursor_pos)) encoding:NSUTF8StringEncoding];
            result[@"cursor"] = @(head ? head.length : [result[@"preedit"] length]);
        }
        result[@"highlighted"] = @(context.menu.highlighted_candidate_index);
        NSMutableArray *candidates = [NSMutableArray array];
        for(int i=0;i<context.menu.num_candidates;i++) {
            if(context.menu.candidates[i].text) [candidates addObject:ERString(context.menu.candidates[i].text)];
        }
        result[@"candidates"] = candidates;
        api->free_context(&context);
    }
    return result;
}
