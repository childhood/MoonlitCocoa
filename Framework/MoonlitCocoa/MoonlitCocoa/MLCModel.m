//
//  MLCModel.m
//  MoonlitCocoa
//
//  Created by Justin Spahr-Summers on 30.10.11.
//  Released into the public domain.
//

#import "MLCModel.h"
#import "MLCState.h"
#import "EXTRuntimeExtensions.h"
#import <objc/runtime.h>

static char * const MLCModelClassAssociatedStateKey = "AssociatedMLCState";

@interface MLCModel ()
/**
 * Enumerates all the properties of the receiver and any superclasses, up until
 * the MLCModel class.
 */
+ (void)enumeratePropertiesUsingBlock:(void (^)(objc_property_t property))block;

/**
 * Returns an array containing the names of all the model properties of the
 * receiver and any superclasses, up until the MLCModel class.
 */
+ (NSArray *)modelPropertyNames;

/**
 * Returns the #MLCState object for this model class. If no Lua state has yet
 * been set up, this will create one and attempt to load a Lua script with the
 * name of the current class and a .mlua or .lua extension.
 */
+ (MLCState *)state;
@end

@implementation MLCModel

- (id)initWithDictionary:(NSDictionary *)dict; {
	self = [super init];
	if (!self)
		return nil;

	[self setValuesForKeysWithDictionary:dict];
	return self;
}

- (NSDictionary *)dictionaryValue; {
	NSArray *keys = [[self class] modelPropertyNames];
	return [self dictionaryWithValuesForKeys:keys];
}

+ (void)enumeratePropertiesUsingBlock:(void (^)(objc_property_t property))block; {
	for (Class cls = self;cls != [MLCModel class];cls = [cls superclass]) {
		unsigned count = 0;
		objc_property_t *properties = class_copyPropertyList(cls, &count);

		if (!properties)
			continue;

		for (unsigned i = 0;i < count;++i) {
			block(properties[i]);
		}

		free(properties);
	}
}

+ (NSArray *)modelPropertyNames; {
	NSMutableArray *names = [[NSMutableArray alloc] init];

	[self enumeratePropertiesUsingBlock:^(objc_property_t property){
		const char *cName = property_getName(property);
		NSString *str = [[NSString alloc] initWithUTF8String:cName];

		[names addObject:str];
	}];

	return names;
}

+ (MLCState *)state; {
	MLCState *state = objc_getAssociatedObject(self, MLCModelClassAssociatedStateKey);
	if (!state) {
		NSBundle *bundle = [NSBundle bundleForClass:self];
		NSString *name = NSStringFromClass([self class]);

		NSURL *scriptURL = [bundle URLForResource:name withExtension:@"mlua"];
		if (!scriptURL) {
			scriptURL = [bundle URLForResource:name withExtension:@"lua"];

			if (!scriptURL) {
				// could not find a script for this class
				return nil;
			}
		}

		state = [[MLCState alloc] init];

		BOOL success = [state enforceStackDelta:0 forBlock:^{
			NSError *error = nil;

			if (![state loadScriptAtURL:scriptURL error:&error]) {
				NSLog(@"Could not initialize model Lua state: %@", error);
				return NO;
			}
			
			if (![state callFunctionWithArgumentCount:0 resultCount:1 error:&error]) {
				NSLog(@"Could not initialize model Lua state: %@", error);
				return NO;
			}

			// CLASSNAME = dofile('CLASSNAME.mlua')
			lua_setglobal(state.state, [name UTF8String]);
			return YES;
		}];

		if (!success)
			return nil;

		objc_setAssociatedObject(self, MLCModelClassAssociatedStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	return state;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
  	NSMethodSignature *signature = [invocation methodSignature];

	NSString *selectorName = NSStringFromSelector([invocation selector]);
	int argumentCount = (int)[signature numberOfArguments];

	int resultCount;
	if ([signature methodReturnLength])
		resultCount = 1;
	else
		resultCount = 0;

	MLCState *state = [[self class] state];

	[state enforceStackDelta:0 forBlock:^{
		NSString *table = NSStringFromClass([self class]);
		[state pushGlobal:table];
		[state popTableAndPushField:selectorName];

		[state pushArgumentsOfInvocation:invocation];

		NSError *error = nil;
		if (![state callFunctionWithArgumentCount:argumentCount - 2 resultCount:resultCount error:&error]) {
			NSLog(@"Exception occurred when invoking %@ in Lua: %@", selectorName, error);
			return NO;
		}

		if (resultCount)
			[state popReturnValueForInvocation:invocation];

		return YES;
	}];
}

- (id)valueForUndefinedKey:(NSString *)key {
	// try invoking Lua
	MLCState *state = [[self class] state];

	__block id result = nil;

	[state enforceStackDelta:0 forBlock:^{
		NSString *table = NSStringFromClass([self class]);
		[state pushGlobal:table];
		[state popTableAndPushField:key];

		NSError *error = nil;
		if (![state callFunctionWithArgumentCount:0 resultCount:1 error:&error]) {
			NSLog(@"Exception occurred when getting key %@ from Lua: %@", key, error);
			return NO;
		}

		result = [state popValueOnStack];
		return YES;
	}];

	return result;
}

#pragma mark NSCoding

- (id)initWithCoder:(NSCoder *)coder {
	NSDictionary *dict = [coder decodeObjectForKey:@"dictionaryValue"];
	return [self initWithDictionary:dict];
}

- (void)encodeWithCoder:(NSCoder *)coder {
	NSDictionary *dict = [self dictionaryValue];
	if (dict)
		[coder encodeObject:dict forKey:@"dictionaryValue"];
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone {
	return self;
}

#pragma mark NSObject

- (NSUInteger)hash {
	return [[self dictionaryValue] hash];
}

- (BOOL)isEqual:(MLCModel *)model {
	// TODO: verify descendant classes, checking for a common ancestor
	if (![model isKindOfClass:[MLCModel class]])
		return NO;
	
	return [[self dictionaryValue] isEqual:[model dictionaryValue]];
}

@end
