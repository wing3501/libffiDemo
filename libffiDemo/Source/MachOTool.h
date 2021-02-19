//
//  MachOTool.h
//  libffiDemo
//
//  Created by styf on 2020/9/2.
//  Copyright © 2020 styf. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MachOTool : NSObject

/// 根据函数名返回函数指针
/// @param funcName 函数名称
+ (void *)funcPtrWithName:(NSString *)funcName;

@end

NS_ASSUME_NONNULL_END
