#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and, if it raises an Objective-C exception, returns the
/// exception's description instead of letting it end the process. Returns
/// nil when the block completes.
///
/// Swift cannot catch NSException: one thrown through a Swift frame calls
/// std::terminate and the app is gone. AVAudioEngine raises them for what it
/// considers programmer error, and a Bluetooth headset changing its format
/// as the tap is installed can look like exactly that. Copied from the Mac
/// app, where every crash report it ever produced was this.
FOUNDATION_EXPORT NSString * _Nullable CLIOMobileCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
