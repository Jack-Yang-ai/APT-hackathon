#import <Foundation/Foundation.h>
BOOL ERInitialize(NSString *shared, NSString *user);
uintptr_t ERCreate(void);
void ERDestroy(uintptr_t session);
BOOL ERProcess(uintptr_t session, int key, int modifiers);
void ERCommit(uintptr_t session);
void ERCommitRaw(uintptr_t session);
void ERClear(uintptr_t session);
void ERSetASCII(uintptr_t session, BOOL enabled);
BOOL ERSelect(uintptr_t session, int index);
NSDictionary *ERSnapshot(uintptr_t session);
