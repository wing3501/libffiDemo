//
//  ViewController.m
//  libffiDemo
//
//  Created by styf on 2020/8/12.
//  Copyright © 2020 styf. All rights reserved.
//

#import "ViewController.h"
#import <objc/runtime.h>
#import "JPMethodSignature.h"
#import "CallFunction.h"
#import "JPBlockWrapper.h"
#import "MachOTool.h"
@interface ViewController ()
///
@property (nonatomic, strong) NSObject *obj;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    
    //测试调用c函数
//    testCfunc(1, 2);
//    [CallFunction callCFunction:@"testCfunc" argTypes:@"void,int,float" arguments:@[@12,@34]];
//    NSNumber *num = [CallFunction callCFunction:@"round" argTypes:@"double,double" arguments:@[@1.6]];
//    NSLog(@"-------->%@",num);
     //测试实例方法
//    [self testInstanceFunc:12 str:@"哈哈"];
//    NSNumber *num = [CallFunction callOCFunction:@"testInstanceFunc:str:" obj:self arguments:@[@23,@"呵呵"]];
//    NSLog(@"------->返回值:%@",num);
    //测试类方法
//    [ViewController testClassFunc:22 str:@"哈哈"];
//    NSNumber *num = [CallFunction callOCFunction:@"testClassFunc:str:" obj:self.class arguments:@[@45,@"哈哈"]];
//    NSLog(@"------->返回值:%@",num);
    
    //测试用NSInvocation调用
//    NSNumber *num = [CallFunction callOCFunctionByNSInvocation:@"testInstanceFunc:str:" obj:self arguments:@[@23,@"呵呵"]];
//    NSLog(@"------->返回值:%@",num);
//    NSNumber *num = [CallFunction callOCFunction:@"testClassFunc:str:" obj:self.class arguments:@[@45,@"哈哈"]];
//    NSLog(@"------->返回值:%@",num);
    
    //performSelector 只能带一个参数
//    [self.class performSelector:@selector(testClassFunc:str:) withObject:@[@123,@"xx"]];
    
    //测试可变参数实例方法
//    NSLog(@"%@",[self testVariableParamInstanceFunc:@3,@1,@2,@3]);
//    NSLog(@"%@",[CallFunction callOCFunctionVariableParamByMsgSend:@"testVariableParamInstanceFunc:" obj:self arguments:@[@3,@4,@2,@3]]);
//    NSLog(@"%@",[CallFunction callOCFunction:@"testVariableParamInstanceFunc:" obj:self arguments:@[@3,@4,@5,@7]]);
    
    //测试可变参数类方法
//    NSLog(@"%@",[ViewController testVariableParamInstanceFunc:@3,@4,@5,@6]);
//    NSLog(@"%@",[CallFunction callOCFunctionVariableParamByMsgSend:@"testVariableParamInstanceFunc:" obj:self.class arguments:@[@3,@4,@5,@6]]);
//    NSLog(@"%@",[CallFunction callOCFunction:@"testVariableParamInstanceFunc:" obj:self.class arguments:@[@3,@4,@5,@6]]);
    
    //libffi生成block
//    JPBlockWrapper *blockWrapper = [[JPBlockWrapper alloc]initWithTypeString:@"id,int,float" callbackFunction:jsfunc];
//    return blockWrapper.blockPtr;
    //js
    //var block = genBlock("float,int,float",function(int a,float b){return a + b;});
//    block(123,1.1);
    
    //不用libffi生成block
//    genCallbackBlock
    
    void *funcPtr = [MachOTool funcPtrWithName:@"_testCfunc"];
    if (funcPtr != NULL) {
        void (*p)(int,float) = funcPtr;
        p(3,4.5);
    }
}

//测试可变参数类方法
+ (NSString *)testVariableParamInstanceFunc:(NSNumber *)n,... {
    va_list ap;
    int largest = 0;
    va_start(ap, n);
    for (int i = 0; i < n.integerValue; i++) {
        NSNumber *curr = va_arg(ap, NSNumber *);
        largest += [curr integerValue];
    }
    va_end(ap);
    return [NSString stringWithFormat:@"总和：%d",largest];
}

//测试可变参数实例方法
- (NSString *)testVariableParamInstanceFunc:(NSNumber *)n,... {
    va_list ap;
    int largest = 0;
    va_start(ap, n);
    for (int i = 0; i < n.integerValue; i++) {
        NSNumber *curr = va_arg(ap, NSNumber *);
        largest += [curr integerValue];
    }
    va_end(ap);
    return [NSString stringWithFormat:@"总和：%d",largest];
}

//测试实例方法
- (NSNumber *)testInstanceFunc:(NSInteger)a str:(NSString *)b {
    NSLog(@"InstanceFunc打印一下:%ld %@",a,b);
    return @200;
}
//测试类方法
+ (NSNumber *)testClassFunc:(NSInteger)a str:(NSString *)b {
    NSLog(@"ClassFunc打印一下:%ld %@",a,b);
    return @100;
}
//测试调用c函数
void testCfunc(int a,float b) {
    printf("打印一下:%d %f",a,b);
}

- (void)testInt:(int)a f:(float)b {
    
}

//v24@0:8@?16
- (void)testBlock:(void(^)(void))block {
    
}

//^@24@0:8#16
- (NSObject **)testClass:(Class)cls {
    void *ptr = &_obj;
    NSLog(@"--------->%p",ptr);
    return NULL;
}

//{CGRect={CGPoint=dd}{CGSize=dd}}32@0:8{CGPoint=dd}16
- (CGRect)getPoint:(CGPoint)point {
    return CGRectZero;
}

void test(int a, double b) {
    
}
@end
