//
//  MLCState.m
//  MoonlitCocoa
//
//  Created by Justin Spahr-Summers on 24.10.11.
//  Released into the public domain.
//

#import "MLCState.h"
#import <lua.h>
#import <lauxlib.h>
#import <lualib.h>

@interface MLCState ()
@property (nonatomic) lua_State *state;
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

	return self;
}

- (void)dealloc {
  	if (self.state) {
		lua_close(self.state);
		self.state = NULL;
	}
}

@end
