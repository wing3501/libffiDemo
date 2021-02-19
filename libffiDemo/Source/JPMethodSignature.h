//
//  JPMethodSignature.h
//  JSPatch
//
//  Created by bang on 1/19/17.
//  Copyright © 2017 bang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ffi.h"

@interface JPMethodSignature : NSObject

@property (nonatomic, readonly) NSString *types;
@property (nonatomic, readonly) NSArray *argumentTypes;
@property (nonatomic, readonly) NSString *returnType;

- (instancetype)initWithObjCTypes:(NSString *)objCTypes;

/// 生成一个Block签名对象
/// @param typeNames 逗号隔开的参数类型字符串  例子：void,id,SEL,int,float
- (instancetype)initWithBlockTypeNames:(NSString *)typeNames;

/// 根据类型字符串返回对应的ffi类型指针
/// @param c 类型字符串
+ (ffi_type *)ffiTypeWithEncodingChar:(const char *)c;
+ (NSString *)typeEncodeWithTypeName:(NSString *)typeName;
+ (NSMutableDictionary *)registeredStruct;
@end
