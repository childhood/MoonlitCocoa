//
//  MLCState.m
//  MoonlitCocoa
//
//  Created by Justin Spahr-Summers on 24.10.11.
//  Released into the public domain.
//

#import "MLCState.h"
#import "MLCBridgedObject.h"
#import "MLCValue.h"
#import "NSDictionary+LuaAdditions.h"
#import "NSNull+LuaAdditions.h"
#import "NSNumber+LuaAdditions.h"
#import "NSString+LuaAdditions.h"
#import <lauxlib.h>
#import <lualib.h>

NSString * const MLCLuaErrorDomain = @"MLCLuaErrorDomain";
NSString * const MLCLuaStackOverflowException = @"MLCLuaStackOverflowException";

@interface MLCState ()
@property (nonatomic, readwrite) lua_State *state;
@end

@implementation MLCState
@synthesize state = m_state;

+ (id)state; {
	return [[self alloc] init];
}

- (id)init; {
  	self = [super init];
	if (!self)
		return nil;
	
	self.state = luaL_newstate();
	luaL_openlibs(self.state);

	// add additional package paths (including the path used by Homebrew)
	[self growStackBySize:2];
	[self enforceStackDelta:0 forBlock:^{
		[self pushGlobal:@"package"];

		lua_pushliteral(self.state, ";;?;?.lua;?.luac;/usr/local/lib/?.luac;/usr/local/lib/?.lua");
		lua_setfield(self.state, -2, "path");
		lua_pop(self.state, 1);
		return YES;
	}];

	// initialize Metalua compiler
	BOOL result = [self enforceStackDelta:0 forBlock:^{
		NSString *compilerPath = [[NSBundle bundleForClass:[self class]] pathForResource:@"compiler" ofType:@"lua"];
		if (0 != luaL_dofile(self.state, [compilerPath UTF8String])) {
			NSLog(@"Could not load Metalua compiler: %@", [NSString popFromStack:self]);
			return NO;
		}

		return YES;
	}];

	if (!result)
		return nil;
	else
		return self;
}

- (void)dealloc {
  	if (self.state) {
		lua_close(self.state);
		self.state = NULL;
	}
}

- (BOOL)callFunctionWithArgumentCount:(int)argCount resultCount:(int)resultCount error:(NSError **)error; {
	int ret = lua_pcall(self.state, argCount, resultCount, 0);
	if (ret == 0) {
		return YES;
	} else {
		if (error) {
			NSDictionary *userInfo = nil;
			NSString *message = [NSString popFromStack:self];
			if (message) {
				userInfo = [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
			}

			*error = [NSError
				errorWithDomain:MLCLuaErrorDomain
				code:ret
				userInfo:userInfo
			];
		}

		return NO;
	}
}

- (id)getValueAtStackIndex:(int)index; {
  	[self growStackBySize:1];

	// duplicate the value in the stack, so that we can pop and then leave the
	// stack in its previous state
  	lua_pushvalue(self.state, index);

	return [self popValueOnStack];
}

- (BOOL)loadScript:(NSString *)source error:(NSError **)error; {
	source = [@"require 'metalua.runtime'\n\n" stringByAppendingString:source];
  
  	[self growStackBySize:2];

	return [self enforceStackDelta:1 forBlock:^{
		[self pushGlobal:@"compiler"];
		[self popTableAndPushField:@"loadstring"];

		[source pushOntoStack:self];

		// on the stack should be:
		// { compiler.loadstring, source }
		return [self callFunctionWithArgumentCount:1 resultCount:1 error:error];
	}];
}

- (BOOL)loadScriptAtURL:(NSURL *)URL error:(NSError **)error; {
  	NSString *source = [NSString stringWithContentsOfURL:URL usedEncoding:NULL error:error];
	if (!source)
		return NO;
	
	return [self loadScript:source error:error];
}

- (BOOL)enforceStackDelta:(int)delta forBlock:(BOOL (^)(void))block; {
  	int top = lua_gettop(self.state);
	BOOL result = block();
	int newTop = lua_gettop(self.state);

	NSAssert2(newTop == top + delta, @"Actual stack delta (%i) does not match expected delta (%i)", newTop - top, delta);

	return result;
}

- (void)growStackBySize:(int)size; {
  	if (!lua_checkstack(self.state, size)) {
		[NSException raise:MLCLuaStackOverflowException format:@"Could not grow Lua stack by %i slots", size];
	}
}

- (void)popTableAndPushField:(NSString *)field; {
	[self growStackBySize:1];
  	lua_getfield(self.state, -1, [field UTF8String]);

	// replace the original table in the stack
	lua_replace(self.state, -2);
}

- (void)popTableAndPushMetatable; {
  	[self growStackBySize:1];
	lua_getmetatable(self.state, -1);

	// replace the original table in the stack
	lua_replace(self.state, -2);
}

- (id)popValueOnStack; {
	switch (lua_type(self.state, -1)) {
	case LUA_TNIL:
		return [NSNull popFromStack:self];

	case LUA_TNUMBER:
	case LUA_TBOOLEAN:
		return [NSNumber popFromStack:self];

	case LUA_TSTRING:
		return [NSString popFromStack:self];

	case LUA_TTABLE:
		return [NSDictionary popFromStack:self];

	case LUA_TLIGHTUSERDATA:
		return (__bridge id)lua_touserdata(self.state, -1);

	case LUA_TTHREAD:
		// TODO: not yet implemented
		//return [MLCState ...
		return nil;

	case LUA_TUSERDATA:
		return [MLCBridgedObject popFromStack:self];
	
	case LUA_TFUNCTION:
	default:
		return nil;
	}
}

- (void)pushArgumentsOfInvocation:(NSInvocation *)invocation; {
	NSMethodSignature *signature = [invocation methodSignature];
	int count = (int)[signature numberOfArguments];

	if (count <= 2)
		return;
	
	[self growStackBySize:count - 2];

	[self enforceStackDelta:count forBlock:^{
		for (int i = 2;i < count;++i) {
			const char *type = [signature getArgumentTypeAtIndex:(NSUInteger)i];
			
			// skip attributes in the provided type encoding
			while (
				*type == 'r' ||
				*type == 'n' ||
				*type == 'N' ||
				*type == 'o' ||
				*type == 'O' ||
				*type == 'R' ||
				*type == 'V'
			) {
				++type;
			}

			#define pushNumberOfType(TYPE) \
				do { \
					TYPE num; \
					[invocation getArgument:&num atIndex:i]; \
					lua_pushnumber(self.state, (lua_Number)num); \
				} while (0)

			switch (*type) {
			case 'c':
				// single characters are pushed as numbers because BOOL is
				// typedef'd to 'char'
				pushNumberOfType(signed char);
				break;

			case 'C':
				pushNumberOfType(unsigned char);
				break;

			case 'i':
				pushNumberOfType(int);
				break;

			case 'I':
				pushNumberOfType(unsigned int);
				break;

			case 's':
				pushNumberOfType(short);
				break;

			case 'S':
				pushNumberOfType(unsigned short);
				break;

			case 'l':
				pushNumberOfType(long);
				break;

			case 'L':
				pushNumberOfType(unsigned long);
				break;

			case 'q':
				pushNumberOfType(long long);
				break;

			case 'Q':
				pushNumberOfType(unsigned long long);
				break;

			case 'f':
				pushNumberOfType(float);
				break;

			case 'd':
				pushNumberOfType(double);
				break;

			case 'B':
				{
					_Bool b;
					[invocation getArgument:&b atIndex:i];
					lua_pushboolean(self.state, b);
				}

				break;

			case '*':
				{
					const char *str;
					[invocation getArgument:&str atIndex:i];
					lua_pushstring(self.state, str);
				}

				break;

			case ':':
				{
					SEL selector;
					[invocation getArgument:&selector atIndex:i];

					const char *name = sel_getName(selector);
					lua_pushstring(self.state, name);
				}

				break;

			case '@':
			case '#':
				{
					id obj;
					[invocation getArgument:&obj atIndex:i];
					[self pushObject:obj];
				}

				break;

			case '^':
				{
					void *ptr;
					[invocation getArgument:&ptr atIndex:i];
					lua_pushlightuserdata(self.state, ptr);
				}

				break;

			default:
				NSLog(@"Unsupported argument type \"%s\", pushing nil", type);
				lua_pushnil(self.state);
			}
		}

		return YES;
	}];
}

- (BOOL)popReturnValueForInvocation:(NSInvocation *)invocation; {
	NSMethodSignature *signature = [invocation methodSignature];

	NSUInteger returnLength = [signature methodReturnLength];
	if (!returnLength)
		return YES;

	const char *type = [signature methodReturnType];
	
	// skip attributes in the provided type encoding
	while (
		*type == 'r' ||
		*type == 'n' ||
		*type == 'N' ||
		*type == 'o' ||
		*type == 'O' ||
		*type == 'R' ||
		*type == 'V'
	) {
		++type;
	}

	#define popNSNumberValue(TYPE, NAME) \
		do { \
			NSNumber *numObj = [NSNumber popFromStack:self]; \
			TYPE num = [numObj NAME ## Value]; \
			[invocation setReturnValue:&num]; \
		} while (0)

	switch (*type) {
	case 'c':
		popNSNumberValue(char, char);
		break;

	case 'C':
		popNSNumberValue(unsigned char, unsignedChar);
		break;

	case 'i':
		popNSNumberValue(int, int);
		break;

	case 'I':
		popNSNumberValue(unsigned int, unsignedInt);
		break;

	case 's':
		popNSNumberValue(short, short);
		break;

	case 'S':
		popNSNumberValue(unsigned short, unsignedShort);
		break;

	case 'l':
		popNSNumberValue(long, long);
		break;

	case 'L':
		popNSNumberValue(unsigned long, unsignedLong);
		break;

	case 'q':
		popNSNumberValue(long long, longLong);
		break;

	case 'Q':
		popNSNumberValue(unsigned long long, unsignedLongLong);
		break;
	
	case 'f':
		popNSNumberValue(float, float);
		break;
	
	case 'd':
		popNSNumberValue(double, double);
		break;
	
	case 'B':
		popNSNumberValue(_Bool, bool);
		break;
	
	case 'v':
		// no return value, nothing to do
		break;
	
	case '*':
		{
			const char *str = lua_tostring(self.state, -1);
			lua_pop(self.state, 1);
			[invocation setReturnValue:&str];
		}

		break;
	
	case '@':
	case '#':
		{
			id obj = [self popValueOnStack];
			[invocation setReturnValue:&obj];
		}

		break;
	
	case ':':
		{
			const char *str = lua_tostring(self.state, -1);
			lua_pop(self.state, 1);

			SEL selector = sel_registerName(str);
			[invocation setReturnValue:&selector];
		}
		
		break;
	
	case '^':
		{
			void *ptr = (void *)lua_topointer(self.state, -1);
			[invocation setReturnValue:&ptr];
		}

		break;

	default:
		NSLog(@"Unsupported return type \"%s\", returning zero", type);

		unsigned char buffer[returnLength];
		memset(buffer, 0, returnLength);
		[invocation setReturnValue:buffer];

		return NO;
	}

	return YES;
}

- (void)pushGlobal:(NSString *)symbol; {
	[self growStackBySize:1];
	lua_getglobal(self.state, [symbol UTF8String]);
}

- (void)pushObject:(id)object; {
	if ([object respondsToSelector:@selector(pushOntoStack:)]) {
		[object pushOntoStack:self];
		return;
	}

	[self growStackBySize:1];

  	if (!object) {
		lua_pushnil(self.state);
	} else {
		lua_pushlightuserdata(self.state, (__bridge void *)object);
	}
}

@end
