#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>

// Uses only in-memory native objects. No CKContainer or database operation is created.
int main(int argc, const char *argv[]) {
    setbuf(stdout, NULL);
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"private";
        NSString *kind = argc > 2 ? @(argv[2]) : @"zone";
        @try {
            CKRecordZoneID *zoneID = [[CKRecordZoneID alloc] initWithZoneName:@"EarnedIt-Probe"
                                                                 ownerName:CKCurrentUserDefaultName];
            CKShare *share = [kind isEqualToString:@"hierarchy"]
                ? [[CKShare alloc] initWithRootRecord:[[CKRecord alloc] initWithRecordType:@"Probe"
                    recordID:[[CKRecordID alloc] initWithRecordName:@"root" zoneID:zoneID]]]
                : [[CKShare alloc] initWithRecordZoneID:zoneID];
            CKShareParticipant *participant = [CKShareParticipant oneTimeURLParticipant];
            printf("factory role=%ld permission=%ld status=%ld publicPermission=%ld\n",
                   (long)participant.role, (long)participant.permission,
                   (long)participant.acceptanceStatus, (long)share.publicPermission);
            if (![mode isEqualToString:@"factory"]) participant.permission = CKShareParticipantPermissionReadWrite;
            if ([mode isEqualToString:@"private"]) participant.role = CKShareParticipantRolePrivateUser;
            if ([mode isEqualToString:@"unknown-role"]) participant.role = CKShareParticipantRoleUnknown;
            if ([mode isEqualToString:@"owner-role"]) participant.role = CKShareParticipantRoleOwner;
            if ([mode isEqualToString:@"public-role"]) participant.role = CKShareParticipantRolePublicUser;
            if ([mode isEqualToString:@"administrator"]) {
                if (@available(iOS 26.0, *)) participant.role = CKShareParticipantRoleAdministrator;
                else return 77;
            }
            if ([mode isEqualToString:@"none-permission"]) participant.permission = CKShareParticipantPermissionNone;
            if ([mode isEqualToString:@"unknown-permission"]) participant.permission = CKShareParticipantPermissionUnknown;
            if ([mode isEqualToString:@"public-share"]) share.publicPermission = CKShareParticipantPermissionReadWrite;
            printf("before-add kind=%s mode=%s role=%ld permission=%ld publicPermission=%ld\n",
                   kind.UTF8String, mode.UTF8String, (long)participant.role,
                   (long)participant.permission, (long)share.publicPermission);
            [share addParticipant:participant];
            if ([mode isEqualToString:@"duplicate"]) [share addParticipant:participant];
            printf("after-add role=%ld permission=%ld participants=%lu\n", (long)participant.role,
                   (long)participant.permission, (unsigned long)share.participants.count);
        } @catch (NSException *exception) {
            printf("exception: %s: %s\n", exception.name.UTF8String, exception.reason.UTF8String);
            return 1;
        }
    }
    return 0;
}
