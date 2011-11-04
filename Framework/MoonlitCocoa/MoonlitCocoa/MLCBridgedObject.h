//
//  MLCBridgedObject.h
//  MoonlitCocoa
//
//  Created by Justin Spahr-Summers on 04.11.11.
//  Released into the public domain.
//

#import <Foundation/Foundation.h>

/**
 * Declares, in a protocol \a NAME, methods that will be implemented in Lua. An
 * object bridged into Lua can then conform to protocol \a NAME to indicate its
 * ability to invoke those Lua methods.
 */
#define lua_interface(NAME) \
	protocol NAME <NSObject> \
	@optional

/**
 * An abstract class representing an Objective-C object that can be bridged as
 * full userdata into Lua.
 */
@interface MLCBridgedObject : NSObject
/**
 * Returns the instance of the receiver corresponding to \a userdata, or \c nil
 * if \a userdata is invalid or does not contain an instance of the receiver.
 *
 * If \a transfer is \c YES, ownership is transferred to ARC (effectively
 * decrementing the object's retain count).
 *
 * @note If an object is associated with \a userdata, but is not an instance of
 * the receiver, and \a transfer is \c YES, ownership of that object is still
 * transferred to ARC, and \c nil is returned.
 */
+ (id)objectFromUserdata:(void *)userdata transferringOwnership:(BOOL)transfer;
@end
