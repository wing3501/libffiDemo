//
//  CallFunction.h
//  libffiDemo
//
//  Created by styf on 2020/8/12.
//  Copyright © 2020 styf. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CallFunction : NSObject
/// libffi调用c函数
/// @param funcName 函数名
/// @param argTypes 参数类型 以逗号分隔 例：void,int,float
/// @param arguments 参数数组
+ (id)callCFunction:(NSString *)funcName argTypes:(NSString *)argTypes arguments:(NSArray *)arguments;

/// libffi调用oc函数
/// @param funcName 函数名
/// @param obj 实例对象或类对象
/// @param arguments 参数数组 不包含消息对象和SEL
+ (id)callOCFunction:(NSString *)funcName obj:(id)obj arguments:(NSArray *)arguments;

/// NSInvocation调用oc函数
/// @param funcName 函数名
/// @param obj 实例对象或类对象
/// @param arguments 参数数组 不包含消息对象和SEL
+ (id)callOCFunctionByNSInvocation:(NSString *)funcName obj:(id)obj arguments:(NSArray *)arguments;

/// objc_msgSend调用oc可变参数函数
/// @param funcName 函数名
/// @param obj 实例对象或类对象
/// @param arguments 参数数组 不包含消息对象和SEL
+ (id)callOCFunctionVariableParamByMsgSend:(NSString *)funcName obj:(id)obj arguments:(NSArray *)arguments;

@end


@interface JPBoxing : NSObject
@property (nonatomic) id obj;
@property (nonatomic) void *pointer;
@property (nonatomic) Class cls;
@property (nonatomic, weak) id weakObj;
@property (nonatomic, assign) id assignObj;
- (id)unbox;
- (void *)unboxPointer;
- (Class)unboxClass;
@end

NS_ASSUME_NONNULL_END
