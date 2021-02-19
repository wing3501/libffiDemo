//
//  CallFunction.m
//  libffiDemo
//
//  Created by styf on 2020/8/12.
//  Copyright © 2020 styf. All rights reserved.
//

#import "CallFunction.h"
#import "ffi.h"
#import <dlfcn.h>
#import "JPMethodSignature.h"
#import <objc/runtime.h>
#import <objc/message.h>

#if CGFLOAT_IS_DOUBLE
#define CGFloatValue doubleValue
#define numberWithCGFloat numberWithDouble
#else
#define CGFloatValue floatValue
#define numberWithCGFloat numberWithFloat
#endif

@implementation JPBoxing

#define JPBOXING_GEN(_name, _prop, _type) \
+ (instancetype)_name:(_type)obj  \
{   \
    JPBoxing *boxing = [[JPBoxing alloc] init]; \
    boxing._prop = obj;   \
    return boxing;  \
}

JPBOXING_GEN(boxObj, obj, id)
JPBOXING_GEN(boxPointer, pointer, void *)
JPBOXING_GEN(boxClass, cls, Class)
JPBOXING_GEN(boxWeakObj, weakObj, id)
JPBOXING_GEN(boxAssignObj, assignObj, id)

- (id)unbox
{
    if (self.obj) return self.obj;
    if (self.weakObj) return self.weakObj;
    if (self.assignObj) return self.assignObj;
    if (self.cls) return self.cls;
    return self;
}
- (void *)unboxPointer
{
    return self.pointer;
}
- (Class)unboxClass
{
    return self.cls;
}
@end

@implementation CallFunction

#pragma mark - public

/// libffi调用c函数
/// @param funcName 函数名
/// @param argTypes 参数类型 以逗号分隔 例：void,int,float
/// @param arguments 参数数组
+ (id)callCFunction:(NSString *)funcName argTypes:(NSString *)argTypes arguments:(NSArray *)arguments {
    //检查下函数指针是否存在
    void* functionPtr = dlsym(RTLD_DEFAULT, [funcName UTF8String]);
    if (!functionPtr) {
        return nil;
    }
    //从函数签名中解析出返回值、参数
    JPMethodSignature *funcSignature = [[JPMethodSignature alloc] initWithObjCTypes:[self CFunctionEncodeStrWithTypes:argTypes]];
    
    NSUInteger argCount = funcSignature.argumentTypes.count;
    if (argCount != [arguments count]){
        return nil;
    }
    //处理参数
    //新建 ffi_type指针数组、参数值指针数据
    ffi_type **ffiArgTypes = alloca(sizeof(ffi_type *) *argCount);
    void **ffiArgs = alloca(sizeof(void *) *argCount);
    for (int i = 0; i < argCount; i ++) {
        const char *argumentType = [funcSignature.argumentTypes[i] UTF8String];//取出每个参数符号  @ : d f
        ffi_type *ffiType = [JPMethodSignature ffiTypeWithEncodingChar:argumentType];//根据符号转成对应的ffi_type指针
        ffiArgTypes[i] = ffiType;//放到类型数组里
        void *ffiArgPtr = alloca(ffiType->size);//申请参数值的内存空间
        [self convertObject:arguments[i] toCValue:ffiArgPtr forType:argumentType];//把参数值赋值到刚刚申请的指针指向的那块内存中
        ffiArgs[i] = ffiArgPtr;//放到值指针数组里
    }
    
    //处理返回值
    ffi_cif cif;
    id ret = nil;
    const char *returnTypeChar = [funcSignature.returnType UTF8String];
    ffi_type *returnFfiType = [JPMethodSignature ffiTypeWithEncodingChar:returnTypeChar];//根据符号转成对应的ffi_type指针
    ffi_status ffiPrepStatus = ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, (unsigned int)0, (unsigned int)argCount, returnFfiType, ffiArgTypes);//校验
    
    if (ffiPrepStatus == FFI_OK) {
        void *returnPtr = NULL;
        if (returnFfiType->size) {//申请返回值的内存空间
            returnPtr = alloca(returnFfiType->size);
        }
        ffi_call(&cif, functionPtr, returnPtr, ffiArgs);//调用函数

        if (returnFfiType->size) {
            ret = [self objectWithCValue:returnPtr forType:returnTypeChar];//把内存中的数据处理成对象返回
        }
    }
    
    return ret;
}


/// libffi调用oc函数
/// @param funcName 函数名
/// @param obj 消息接受对象 实例对象或类对象
/// @param arguments 参数数组不包含消息对象和SEL
+ (id)callOCFunction:(NSString *)funcName obj:(id)obj arguments:(NSArray *)arguments {
    SEL sel = NSSelectorFromString(funcName);
    IMP imp = NULL;
    BOOL instanceMethod = !object_isClass(obj);
    NSMethodSignature *methodSignature;
    if (instanceMethod) {
        Method m = class_getInstanceMethod([obj class], sel);
        imp = method_getImplementation(m);
        methodSignature = [obj methodSignatureForSelector:sel];
    }else{
        Class clazz = (Class)obj;
        Method m = class_getClassMethod(clazz, sel);
        imp = method_getImplementation(m);
        methodSignature = [clazz methodSignatureForSelector:sel];
    }
    
    //检查下函数指针是否存在
    if (!imp) {
        return nil;
    }
    
    BOOL isVariadic = NO;//是否是可变参数的方法
    NSUInteger argCount = methodSignature.numberOfArguments;//签名上的参数个数 包含self/SEL
    NSUInteger argumentCount = [arguments count];//实际的参数个数 不包含self/SEL
    if (argumentCount > argCount - 2){//除了obj和SEL,实际传进来的参数比签名的参数个数多，说明是可变参数的函数
        isVariadic = YES;
        argCount = argumentCount + 2 + 1; // @SatanWoo:append self/SEL and NULL as nil termination
    }
    //处理参数
    //新建 ffi_type指针数组、参数值指针数据
    ffi_type **ffiArgTypes = alloca(sizeof(ffi_type *) *argCount);
    void **ffiArgs = alloca(sizeof(void *) *argCount);
    
    ffiArgTypes[0] = &ffi_type_pointer;//第一个参数是self,类型是指针
    ffiArgs[0] = &obj;
    
    ffiArgTypes[1] = &ffi_type_pointer;//第二个参数SEL
    ffiArgs[1] = &sel;
    //把传进来的参数依次放进数组内
    for (int i = 0; i < argumentCount; i ++) {
        const char *argumentType;
        if (isVariadic && i >= methodSignature.numberOfArguments - 2) {
            argumentType = [methodSignature getArgumentTypeAtIndex:methodSignature.numberOfArguments - 1];//可变参数的后面几个参数类型都和第一个可变参数类型一样
        }else {
            argumentType = [methodSignature getArgumentTypeAtIndex:i + 2];//取出每个参数符号  @ : d f
        }
        ffi_type *ffiType = [JPMethodSignature ffiTypeWithEncodingChar:argumentType];//根据符号转成对应的ffi_type指针
        ffiArgTypes[i + 2] = ffiType;//放到类型数组里
        void *ffiArgPtr = alloca(ffiType->size);//申请参数值的内存空间
        [self convertObject:arguments[i] toCValue:ffiArgPtr forType:argumentType];//把参数值赋值到刚刚申请的指针指向的那块内存中
        ffiArgs[i + 2] = ffiArgPtr;//放到值指针数组里
    }
    
    if (isVariadic) {//可变参数的最后一个参数NULL
        ffiArgTypes[argCount - 1] = &ffi_type_pointer;
        void *ffiArgPtr = alloca(ffi_type_pointer.size);
        memset(ffiArgPtr, 0, ffi_type_pointer.size);
        ffiArgs[argCount - 1] = ffiArgPtr;
    }
    
    //处理返回值
    ffi_cif cif;
    id ret = nil;
    const char *returnTypeChar = methodSignature.methodReturnType;
    ffi_type *returnFfiType = [JPMethodSignature ffiTypeWithEncodingChar:returnTypeChar];//根据符号转成对应的ffi_type指针
    ffi_status ffiPrepStatus = ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, (unsigned int)0, (unsigned int)argCount, returnFfiType, ffiArgTypes);//校验
    
    if (ffiPrepStatus == FFI_OK) {
        void *returnPtr = NULL;
        if (returnFfiType->size) {//申请返回值的内存空间
            returnPtr = alloca(returnFfiType->size);
        }
        ffi_call(&cif, imp, returnPtr, ffiArgs);//调用函数

        if (returnFfiType->size) {
            ret = [self objectWithCValue:returnPtr forType:returnTypeChar];//把内存中的数据处理成对象返回
        }
    }
    
    return ret;
}

/// NSInvocation调用oc函数
/// @param funcName 函数名
/// @param obj 实例对象或类对象
/// @param arguments 参数数组 不包含消息对象和SEL
+ (id)callOCFunctionByNSInvocation:(NSString *)funcName obj:(id)obj arguments:(NSArray *)arguments {
    SEL sel = NSSelectorFromString(funcName);
    IMP imp = NULL;
    BOOL instanceMethod = !object_isClass(obj);
    NSMethodSignature *methodSignature;
    if (instanceMethod) {
        Method m = class_getInstanceMethod([obj class], sel);
        imp = method_getImplementation(m);
        methodSignature = [obj methodSignatureForSelector:sel];
    }else{
        Class clazz = (Class)obj;
        Method m = class_getClassMethod(clazz, sel);
        imp = method_getImplementation(m);
        methodSignature = [clazz methodSignatureForSelector:sel];
    }
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    [invocation setTarget:obj];
    [invocation setSelector:sel];
    
    NSUInteger numberOfArguments = methodSignature.numberOfArguments;
    NSInteger inputArguments = [arguments count];
    if (inputArguments > numberOfArguments - 2) {
        //可变参数函数调用
        return [self callOCFunctionVariableParamByMsgSend:funcName obj:obj arguments:arguments];
    }
    
    for (NSUInteger i = 2; i < numberOfArguments; i++) {
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:i];
        id valObj = arguments[i - 2];
        switch (argumentType[0] == 'r' ? argumentType[1] : argumentType[0]) {
                
                #define CALL_ARG_CASE(_typeString, _type, _selector) \
                case _typeString: {                              \
                    _type value = [valObj _selector];                     \
                    [invocation setArgument:&value atIndex:i];\
                    break; \
                }
                
                CALL_ARG_CASE('c', char, charValue)
                CALL_ARG_CASE('C', unsigned char, unsignedCharValue)
                CALL_ARG_CASE('s', short, shortValue)
                CALL_ARG_CASE('S', unsigned short, unsignedShortValue)
                CALL_ARG_CASE('i', int, intValue)
                CALL_ARG_CASE('I', unsigned int, unsignedIntValue)
                CALL_ARG_CASE('l', long, longValue)
                CALL_ARG_CASE('L', unsigned long, unsignedLongValue)
                CALL_ARG_CASE('q', long long, longLongValue)
                CALL_ARG_CASE('Q', unsigned long long, unsignedLongLongValue)
                CALL_ARG_CASE('f', float, floatValue)
                CALL_ARG_CASE('d', double, doubleValue)
                CALL_ARG_CASE('B', BOOL, boolValue)
                
            case ':': {
                SEL value = NSSelectorFromString(valObj);
                [invocation setArgument:&value atIndex:i];
                break;
            }
            case '{': {
                NSString *typeString = extractStructName([NSString stringWithUTF8String:argumentType]);
                NSValue *val = arguments[i - 2];
                #define JP_CALL_ARG_STRUCT(_type, _methodName) \
                if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                    _type value = [val _methodName];  \
                    [invocation setArgument:&value atIndex:i];  \
                    break; \
                }
                JP_CALL_ARG_STRUCT(CGRect, CGRectValue)
                JP_CALL_ARG_STRUCT(CGPoint, CGPointValue)
                JP_CALL_ARG_STRUCT(CGSize, CGSizeValue)
                JP_CALL_ARG_STRUCT(NSRange, rangeValue)
                @synchronized (self) {
                    NSDictionary *structDefine = [JPMethodSignature registeredStruct][typeString];
                    if (structDefine) {
                        size_t size = sizeOfStructTypes(structDefine[@"types"]);
                        void *ret = malloc(size);
                        getStructDataWithDict(ret, valObj, structDefine);
                        [invocation setArgument:ret atIndex:i];
                        free(ret);
                        break;
                    }
                }
                
                break;
            }
            case '*':
            case '^': {
                if ([valObj isKindOfClass:[JPBoxing class]]) {
                    void *value = [((JPBoxing *)valObj) unboxPointer];
                    
//                    if (argumentType[1] == '@') {
//                        if (!_TMPMemoryPool) {
//                            _TMPMemoryPool = [[NSMutableDictionary alloc] init];
//                        }
//                        if (!_markArray) {
//                            _markArray = [[NSMutableArray alloc] init];
//                        }
//                        memset(value, 0, sizeof(id));
//                        [_markArray addObject:valObj];
//                    }
                    
                    [invocation setArgument:&value atIndex:i];
                    break;
                }
            }
            case '#': {
                if ([valObj isKindOfClass:[JPBoxing class]]) {
                    Class value = [((JPBoxing *)valObj) unboxClass];
                    [invocation setArgument:&value atIndex:i];
                    break;
                }
            }
            default: {
//                if (valObj == _nullObj) {
//                    valObj = [NSNull null];
//                    [invocation setArgument:&valObj atIndex:i];
//                    break;
//                }
//                if (valObj == _nilObj ||
//                    ([valObj isKindOfClass:[NSNumber class]] && strcmp([valObj objCType], "c") == 0 && ![valObj boolValue])) {
//                    valObj = nil;
//                    [invocation setArgument:&valObj atIndex:i];
//                    break;
//                }
//                if ([(JSValue *)arguments[i-2] hasProperty:@"__isBlock"]) {
//                    JSValue *blkJSVal = arguments[i-2];
//                    Class JPBlockClass = NSClassFromString(@"JPBlock");
//                    if (JPBlockClass && ![blkJSVal[@"blockObj"] isUndefined]) {
//                        __autoreleasing id cb = [JPBlockClass performSelector:@selector(blockWithBlockObj:) withObject:[blkJSVal[@"blockObj"] toObject]];
//                        [invocation setArgument:&cb atIndex:i];
//                        Block_release((__bridge void *)cb);
//                    } else {
//                        __autoreleasing id cb = genCallbackBlock(arguments[i-2]);
//                        [invocation setArgument:&cb atIndex:i];
//                    }
//                } else {
                    [invocation setArgument:&valObj atIndex:i];
//                }
            }
        }
    }

    [invocation invoke];//执行方法
    
    char returnType[255];
    strcpy(returnType, [methodSignature methodReturnType]);
    
    //获取并处理返回值
    id returnValue;
    if (strncmp(returnType, "v", 1) != 0) {
        if (strncmp(returnType, "@", 1) == 0) {
            void *result;
            [invocation getReturnValue:&result];
            
            //For performance, ignore the other methods prefix with alloc/new/copy/mutableCopy
            if ([funcName isEqualToString:@"alloc"] || [funcName isEqualToString:@"new"] ||
                [funcName isEqualToString:@"copy"] || [funcName isEqualToString:@"mutableCopy"]) {
                returnValue = (__bridge_transfer id)result;
            } else {
                returnValue = (__bridge id)result;
            }
            return returnValue;
            
        } else {
            switch (returnType[0] == 'r' ? returnType[1] : returnType[0]) {
                    
                #define JP_CALL_RET_CASE(_typeString, _type) \
                case _typeString: {                              \
                    _type tempResultSet; \
                    [invocation getReturnValue:&tempResultSet];\
                    returnValue = @(tempResultSet); \
                    break; \
                }
                    
                JP_CALL_RET_CASE('c', char)
                JP_CALL_RET_CASE('C', unsigned char)
                JP_CALL_RET_CASE('s', short)
                JP_CALL_RET_CASE('S', unsigned short)
                JP_CALL_RET_CASE('i', int)
                JP_CALL_RET_CASE('I', unsigned int)
                JP_CALL_RET_CASE('l', long)
                JP_CALL_RET_CASE('L', unsigned long)
                JP_CALL_RET_CASE('q', long long)
                JP_CALL_RET_CASE('Q', unsigned long long)
                JP_CALL_RET_CASE('f', float)
                JP_CALL_RET_CASE('d', double)
                JP_CALL_RET_CASE('B', BOOL)

                case '{': {
                    NSString *typeString = extractStructName([NSString stringWithUTF8String:returnType]);
                    #define JP_CALL_RET_STRUCT(_type, _methodName) \
                    if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                        _type result;   \
                        [invocation getReturnValue:&result];    \
                        return [NSValue _methodName:result];    \
                    }
                    JP_CALL_RET_STRUCT(CGRect, valueWithCGRect)
                    JP_CALL_RET_STRUCT(CGPoint, valueWithCGPoint)
                    JP_CALL_RET_STRUCT(CGSize, valueWithCGSize)
                    JP_CALL_RET_STRUCT(NSRange, valueWithRange)
                    @synchronized (self) {
                        NSDictionary *structDefine = [JPMethodSignature registeredStruct][typeString];
                        if (structDefine) {
                            size_t size = sizeOfStructTypes(structDefine[@"types"]);
                            void *ret = malloc(size);
                            [invocation getReturnValue:ret];
                            NSDictionary *dict = getDictOfStruct(ret, structDefine);
                            free(ret);
                            return dict;
                        }
                    }
                    break;
                }
                case '*':
                case '^': {
                    void *result;
                    [invocation getReturnValue:&result];
                    returnValue = [NSValue valueWithPointer:result];
//                    if (strncmp(returnType, "^{CG", 4) == 0) {
//                        if (!_pointersToRelease) {
//                            _pointersToRelease = [[NSMutableArray alloc] init];
//                        }
//                        [_pointersToRelease addObject:[NSValue valueWithPointer:result]];
//                        CFRetain(result);
//                    }
                    break;
                }
                case '#': {
                    Class result;
                    [invocation getReturnValue:&result];
                    returnValue = result;
                    break;
                }
            }
            return returnValue;
        }
    }
    return nil;
}


static id (*new_msgSend1)(id, SEL, id,...) = (id (*)(id, SEL, id,...)) objc_msgSend;
static id (*new_msgSend2)(id, SEL, id, id,...) = (id (*)(id, SEL, id, id,...)) objc_msgSend;
static id (*new_msgSend3)(id, SEL, id, id, id,...) = (id (*)(id, SEL, id, id, id,...)) objc_msgSend;
static id (*new_msgSend4)(id, SEL, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend5)(id, SEL, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend6)(id, SEL, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend7)(id, SEL, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id,id,...)) objc_msgSend;
static id (*new_msgSend8)(id, SEL, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend9)(id, SEL, id, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id, id, ...)) objc_msgSend;
static id (*new_msgSend10)(id, SEL, id, id, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id, id, id,...)) objc_msgSend;

/// objc_msgSend调用oc可变参数函数
/// @param funcName 函数名
/// @param sender 实例对象或类对象
/// @param arguments 参数数组 不包含消息对象和SEL
+ (id)callOCFunctionVariableParamByMsgSend:(NSString *)funcName obj:(id)sender arguments:(NSArray *)arguments {
    SEL selector = NSSelectorFromString(funcName);
    NSMethodSignature *methodSignature = [sender methodSignatureForSelector:selector];
    NSInteger inputArguments = [(NSArray *)arguments count];
    NSUInteger numberOfArguments = methodSignature.numberOfArguments;
    
    NSMutableArray *argumentsList = [[NSMutableArray alloc] init];
    for (NSUInteger j = 0; j < inputArguments; j++) {
        NSInteger index = MIN(j + 2, numberOfArguments - 1);//取可变参数的第一个下标
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:index];
        id valObj = arguments[j];
        char argumentTypeChar = argumentType[0] == 'r' ? argumentType[1] : argumentType[0];//可变参数的参数类型
        if (argumentTypeChar == '@') {
            [argumentsList addObject:valObj];
        } else {
            return nil;
        }
    }
    
    id results = nil;
    numberOfArguments = numberOfArguments - 2;
    
    //If you want to debug the macro code below, replace it to the expanded code:
    //https://gist.github.com/bang590/ca3720ae1da594252a2e
    #define JP_G_ARG(_idx) getArgument(argumentsList[_idx])
    #define JP_CALL_MSGSEND_ARG1(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0));
    #define JP_CALL_MSGSEND_ARG2(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1));
    #define JP_CALL_MSGSEND_ARG3(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2));
    #define JP_CALL_MSGSEND_ARG4(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3));
    #define JP_CALL_MSGSEND_ARG5(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4));
    #define JP_CALL_MSGSEND_ARG6(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5));
    #define JP_CALL_MSGSEND_ARG7(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6));
    #define JP_CALL_MSGSEND_ARG8(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7));
    #define JP_CALL_MSGSEND_ARG9(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8));
    #define JP_CALL_MSGSEND_ARG10(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8), JP_G_ARG(9));
    #define JP_CALL_MSGSEND_ARG11(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8), JP_G_ARG(9), JP_G_ARG(10));

    #define JP_IF_REAL_ARG_COUNT(_num) if([argumentsList count] == _num)

    #define JP_DEAL_MSGSEND(_realArgCount, _defineArgCount) \
        if(numberOfArguments == _defineArgCount) { \
            JP_CALL_MSGSEND_ARG##_realArgCount(_defineArgCount) \
        }

    JP_IF_REAL_ARG_COUNT(1) { JP_CALL_MSGSEND_ARG1(1) }
    JP_IF_REAL_ARG_COUNT(2) { JP_DEAL_MSGSEND(2, 1) JP_DEAL_MSGSEND(2, 2) }
    JP_IF_REAL_ARG_COUNT(3) { JP_DEAL_MSGSEND(3, 1) JP_DEAL_MSGSEND(3, 2) JP_DEAL_MSGSEND(3, 3) }
    JP_IF_REAL_ARG_COUNT(4) { JP_DEAL_MSGSEND(4, 1) JP_DEAL_MSGSEND(4, 2) JP_DEAL_MSGSEND(4, 3) JP_DEAL_MSGSEND(4, 4) }
    JP_IF_REAL_ARG_COUNT(5) { JP_DEAL_MSGSEND(5, 1) JP_DEAL_MSGSEND(5, 2) JP_DEAL_MSGSEND(5, 3) JP_DEAL_MSGSEND(5, 4) JP_DEAL_MSGSEND(5, 5) }
    JP_IF_REAL_ARG_COUNT(6) { JP_DEAL_MSGSEND(6, 1) JP_DEAL_MSGSEND(6, 2) JP_DEAL_MSGSEND(6, 3) JP_DEAL_MSGSEND(6, 4) JP_DEAL_MSGSEND(6, 5) JP_DEAL_MSGSEND(6, 6) }
    JP_IF_REAL_ARG_COUNT(7) { JP_DEAL_MSGSEND(7, 1) JP_DEAL_MSGSEND(7, 2) JP_DEAL_MSGSEND(7, 3) JP_DEAL_MSGSEND(7, 4) JP_DEAL_MSGSEND(7, 5) JP_DEAL_MSGSEND(7, 6) JP_DEAL_MSGSEND(7, 7) }
    JP_IF_REAL_ARG_COUNT(8) { JP_DEAL_MSGSEND(8, 1) JP_DEAL_MSGSEND(8, 2) JP_DEAL_MSGSEND(8, 3) JP_DEAL_MSGSEND(8, 4) JP_DEAL_MSGSEND(8, 5) JP_DEAL_MSGSEND(8, 6) JP_DEAL_MSGSEND(8, 7) JP_DEAL_MSGSEND(8, 8) }
    JP_IF_REAL_ARG_COUNT(9) { JP_DEAL_MSGSEND(9, 1) JP_DEAL_MSGSEND(9, 2) JP_DEAL_MSGSEND(9, 3) JP_DEAL_MSGSEND(9, 4) JP_DEAL_MSGSEND(9, 5) JP_DEAL_MSGSEND(9, 6) JP_DEAL_MSGSEND(9, 7) JP_DEAL_MSGSEND(9, 8) JP_DEAL_MSGSEND(9, 9) }
    JP_IF_REAL_ARG_COUNT(10) { JP_DEAL_MSGSEND(10, 1) JP_DEAL_MSGSEND(10, 2) JP_DEAL_MSGSEND(10, 3) JP_DEAL_MSGSEND(10, 4) JP_DEAL_MSGSEND(10, 5) JP_DEAL_MSGSEND(10, 6) JP_DEAL_MSGSEND(10, 7) JP_DEAL_MSGSEND(10, 8) JP_DEAL_MSGSEND(10, 9) JP_DEAL_MSGSEND(10, 10) }
    
    return results;
}


#pragma mark - block



#pragma mark - private

/// 把值根据类型赋值到指定内存中
/// @param object 值
/// @param dist 目标内存指针
/// @param typeString 类型字符串
+ (void)convertObject:(id)object toCValue:(void *)dist forType:(const char *)typeString
{
#define JP_CALL_ARG_CASE(_typeString, _type, _selector)\
    case _typeString:{\
        *(_type *)dist = [(NSNumber *)object _selector];\
        break;\
    }
    switch (typeString[0]) {
        JP_CALL_ARG_CASE('c', char, charValue)
        JP_CALL_ARG_CASE('C', unsigned char, unsignedCharValue)
        JP_CALL_ARG_CASE('s', short, shortValue)
        JP_CALL_ARG_CASE('S', unsigned short, unsignedShortValue)
        JP_CALL_ARG_CASE('i', int, intValue)
        JP_CALL_ARG_CASE('I', unsigned int, unsignedIntValue)
        JP_CALL_ARG_CASE('l', long, longValue)
        JP_CALL_ARG_CASE('L', unsigned long, unsignedLongValue)
        JP_CALL_ARG_CASE('q', long long, longLongValue)
        JP_CALL_ARG_CASE('Q', unsigned long long, unsignedLongLongValue)
        JP_CALL_ARG_CASE('f', float, floatValue)
        JP_CALL_ARG_CASE('F', CGFloat, CGFloatValue)
        JP_CALL_ARG_CASE('d', double, doubleValue)
        JP_CALL_ARG_CASE('B', BOOL, boolValue)
        case '^': {
            void *ptr = [((JPBoxing *)object) unboxPointer];
            *(void **)dist = ptr;
            break;
        }
        case '#':
        case '@': {
            id ptr = object;
            *(void **)dist = (__bridge void *)(ptr);
            break;
        }
        case '{': {
            NSString *structName = [NSString stringWithCString:typeString encoding:NSASCIIStringEncoding];
            NSUInteger end = [structName rangeOfString:@"}"].location;
            if (end != NSNotFound) {
                structName = [structName substringWithRange:NSMakeRange(1, end - 1)];
                NSDictionary *structDefine = [JPMethodSignature registeredStruct][structName];
                 getStructDataWithDict(dist, object, structDefine);//把字典里的结构体数据值写入到指定内存中
                break;
            }
        }
        default:
            break;
    }
}

/// 把指定内存的值根据类型转成对象
/// @param src 指定内存指针
/// @param typeString 类型字符串
+ (id)objectWithCValue:(void *)src forType:(const char *)typeString
{
    switch (typeString[0]) {
    #define JP_FFI_RETURN_CASE(_typeString, _type, _selector)\
        case _typeString:{\
            _type v = *(_type *)src;\
            return [NSNumber _selector:v];\
        }
        JP_FFI_RETURN_CASE('c', char, numberWithChar)
        JP_FFI_RETURN_CASE('C', unsigned char, numberWithUnsignedChar)
        JP_FFI_RETURN_CASE('s', short, numberWithShort)
        JP_FFI_RETURN_CASE('S', unsigned short, numberWithUnsignedShort)
        JP_FFI_RETURN_CASE('i', int, numberWithInt)
        JP_FFI_RETURN_CASE('I', unsigned int, numberWithUnsignedInt)
        JP_FFI_RETURN_CASE('l', long, numberWithLong)
        JP_FFI_RETURN_CASE('L', unsigned long, numberWithUnsignedLong)
        JP_FFI_RETURN_CASE('q', long long, numberWithLongLong)
        JP_FFI_RETURN_CASE('Q', unsigned long long, numberWithUnsignedLongLong)
        JP_FFI_RETURN_CASE('f', float, numberWithFloat)
        JP_FFI_RETURN_CASE('F', CGFloat, numberWithCGFloat)
        JP_FFI_RETURN_CASE('d', double, numberWithDouble)
        JP_FFI_RETURN_CASE('B', BOOL, numberWithBool)
        case '^': {
            JPBoxing *box = [[JPBoxing alloc] init];
            box.pointer = (*(void**)src);
            return box;
        }
        case '@':
        case '#': {
            return (__bridge id)(*(void**)src);
        }
        case '{': {
            NSString *structName = [NSString stringWithCString:typeString encoding:NSASCIIStringEncoding];
            NSUInteger end = [structName rangeOfString:@"}"].location;
            if (end != NSNotFound) {
                structName = [structName substringWithRange:NSMakeRange(1, end - 1)];
                NSDictionary *structDefine = [JPMethodSignature registeredStruct][structName];
                id ret = getDictOfStruct(src, structDefine);//类型是结构体，把内存中的数据转成字典
                return ret;
            }
        }
        default:
            return nil;
    }
}

/// 把字典里的结构体数据值写入到指定内存中
/// @param structData 目标内存指针
/// @param dict 字典数据
/// @param structDefine 结构体定义信息字段
static void getStructDataWithDict(void *structData, NSDictionary *dict, NSDictionary *structDefine)
{
    NSArray *itemKeys = structDefine[@"keys"];
    const char *structTypes = [structDefine[@"types"] cStringUsingEncoding:NSUTF8StringEncoding];
    int position = 0;
    for (NSString *itemKey in itemKeys) {
        switch(*structTypes) {
            #define JP_STRUCT_DATA_CASE(_typeStr, _type, _transMethod) \
            case _typeStr: { \
                int size = sizeof(_type);    \
                _type val = [dict[itemKey] _transMethod];   \
                memcpy(structData + position, &val, size);  \
                position += size;    \
                break;  \
            }
                
            JP_STRUCT_DATA_CASE('c', char, charValue)
            JP_STRUCT_DATA_CASE('C', unsigned char, unsignedCharValue)
            JP_STRUCT_DATA_CASE('s', short, shortValue)
            JP_STRUCT_DATA_CASE('S', unsigned short, unsignedShortValue)
            JP_STRUCT_DATA_CASE('i', int, intValue)
            JP_STRUCT_DATA_CASE('I', unsigned int, unsignedIntValue)
            JP_STRUCT_DATA_CASE('l', long, longValue)
            JP_STRUCT_DATA_CASE('L', unsigned long, unsignedLongValue)
            JP_STRUCT_DATA_CASE('q', long long, longLongValue)
            JP_STRUCT_DATA_CASE('Q', unsigned long long, unsignedLongLongValue)
            JP_STRUCT_DATA_CASE('f', float, floatValue)
            JP_STRUCT_DATA_CASE('F', CGFloat, CGFloatValue)
            JP_STRUCT_DATA_CASE('d', double, doubleValue)
            JP_STRUCT_DATA_CASE('B', BOOL, boolValue)
            JP_STRUCT_DATA_CASE('N', NSInteger, integerValue)
            JP_STRUCT_DATA_CASE('U', NSUInteger, unsignedIntegerValue)
            
            case '*':
            case '^': {
                int size = sizeof(void *);
                void *val = [(JPBoxing *)dict[itemKey] unboxPointer];
                memcpy(structData + position, &val, size);
                break;
            }
            case '{': {
                NSString *subStructName = [NSString stringWithCString:structTypes encoding:NSASCIIStringEncoding];
                NSUInteger end = [subStructName rangeOfString:@"}"].location;
                if (end != NSNotFound) {
                    subStructName = [subStructName substringWithRange:NSMakeRange(1, end - 1)];
                    NSDictionary *subStructDefine = [JPMethodSignature registeredStruct][subStructName];
                    NSDictionary *subDict = dict[itemKey];
                    int size = sizeOfStructTypes(subStructDefine[@"types"]);
                    getStructDataWithDict(structData + position, subDict, subStructDefine);
                    position += size;
                    structTypes += end;
                    break;
                }
            }
            default:
                break;
            
        }
        structTypes ++;
    }
}

/// 把指针指向的内存数据转成字典
/// @param structData 指针
/// @param structDefine 事先定义好的结构体信息
static NSDictionary *getDictOfStruct(void *structData, NSDictionary *structDefine)
{
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    NSArray *itemKeys = structDefine[@"keys"];
    const char *structTypes = [structDefine[@"types"] cStringUsingEncoding:NSUTF8StringEncoding];
    int position = 0;
    
    for (NSString *itemKey in itemKeys) {
        switch(*structTypes) {
            #define JP_STRUCT_DICT_CASE(_typeName, _type)   \
            case _typeName: { \
                size_t size = sizeof(_type); \
                _type *val = malloc(size);   \
                memcpy(val, structData + position, size);   \
                [dict setObject:@(*val) forKey:itemKey];    \
                free(val);  \
                position += size;   \
                break;  \
            }
            JP_STRUCT_DICT_CASE('c', char)
            JP_STRUCT_DICT_CASE('C', unsigned char)
            JP_STRUCT_DICT_CASE('s', short)
            JP_STRUCT_DICT_CASE('S', unsigned short)
            JP_STRUCT_DICT_CASE('i', int)
            JP_STRUCT_DICT_CASE('I', unsigned int)
            JP_STRUCT_DICT_CASE('l', long)
            JP_STRUCT_DICT_CASE('L', unsigned long)
            JP_STRUCT_DICT_CASE('q', long long)
            JP_STRUCT_DICT_CASE('Q', unsigned long long)
            JP_STRUCT_DICT_CASE('f', float)
            JP_STRUCT_DICT_CASE('F', CGFloat)
            JP_STRUCT_DICT_CASE('N', NSInteger)
            JP_STRUCT_DICT_CASE('U', NSUInteger)
            JP_STRUCT_DICT_CASE('d', double)
            JP_STRUCT_DICT_CASE('B', BOOL)
            
            case '*':
            case '^': {
                size_t size = sizeof(void *);
                void *val = malloc(size);
                memcpy(val, structData + position, size);
                [dict setObject:[JPBoxing boxPointer:val] forKey:itemKey];
                position += size;
                break;
            }
            case '{': {
                NSString *subStructName = [NSString stringWithCString:structTypes encoding:NSASCIIStringEncoding];
                NSUInteger end = [subStructName rangeOfString:@"}"].location;
                if (end != NSNotFound) {
                    subStructName = [subStructName substringWithRange:NSMakeRange(1, end - 1)];
                    NSDictionary *subStructDefine = [JPMethodSignature registeredStruct][subStructName];
                    int size = sizeOfStructTypes(subStructDefine[@"types"]);
                    NSDictionary *subDict = getDictOfStruct(structData + position, subStructDefine);
                    [dict setObject:subDict forKey:itemKey];
                    position += size;
                    structTypes += end;
                    break;
                }
            }
        }
        structTypes ++;
    }
    return dict;
}


/// 根据结构体的类型字符串返回结构体所占内存大小
/// @param structTypes 类型字符串  例： “FFFFFF”
static int sizeOfStructTypes(NSString *structTypes)
{
    const char *types = [structTypes cStringUsingEncoding:NSUTF8StringEncoding];
    int index = 0;
    int size = 0;
    while (types[index]) {
        switch (types[index]) {
            #define JP_STRUCT_SIZE_CASE(_typeChar, _type)   \
            case _typeChar: \
                size += sizeof(_type);  \
                break;
                
            JP_STRUCT_SIZE_CASE('c', char)
            JP_STRUCT_SIZE_CASE('C', unsigned char)
            JP_STRUCT_SIZE_CASE('s', short)
            JP_STRUCT_SIZE_CASE('S', unsigned short)
            JP_STRUCT_SIZE_CASE('i', int)
            JP_STRUCT_SIZE_CASE('I', unsigned int)
            JP_STRUCT_SIZE_CASE('l', long)
            JP_STRUCT_SIZE_CASE('L', unsigned long)
            JP_STRUCT_SIZE_CASE('q', long long)
            JP_STRUCT_SIZE_CASE('Q', unsigned long long)
            JP_STRUCT_SIZE_CASE('f', float)
            JP_STRUCT_SIZE_CASE('F', CGFloat)
            JP_STRUCT_SIZE_CASE('N', NSInteger)
            JP_STRUCT_SIZE_CASE('U', NSUInteger)
            JP_STRUCT_SIZE_CASE('d', double)
            JP_STRUCT_SIZE_CASE('B', BOOL)
            JP_STRUCT_SIZE_CASE('*', void *)
            JP_STRUCT_SIZE_CASE('^', void *)
                
            case '{': {
                NSString *structTypeStr = [structTypes substringFromIndex:index];
                NSUInteger end = [structTypeStr rangeOfString:@"}"].location;
                if (end != NSNotFound) {
                    NSString *subStructName = [structTypeStr substringWithRange:NSMakeRange(1, end - 1)];
                    NSDictionary *subStructDefine = [JPMethodSignature registeredStruct][subStructName];
                    NSString *subStructTypes = subStructDefine[@"types"];
                    size += sizeOfStructTypes(subStructTypes);
                    index += (int)end;
                    break;
                }
            }
            
            default:
                break;
        }
        index ++;
    }
    return size;
}

/// 把逗号分隔的参数类型 转成函数签名字符串  void,int,float --->  vif
/// @param types 参数类型 以逗号分隔 例：void,int,float
+ (NSString *)CFunctionEncodeStrWithTypes:(NSString *)types {
    NSMutableString *encodeStr = [[NSMutableString alloc] init];
    NSArray *typeArr = [types componentsSeparatedByString:@","];
    for (NSInteger i = 0; i < typeArr.count; i++) {
        NSString *typeStr = trim([typeArr objectAtIndex:i]);
        NSString *encode = [JPMethodSignature typeEncodeWithTypeName:typeStr];
        if (!encode) {
            if ([typeStr hasPrefix:@"{"] && [typeStr hasSuffix:@"}"]) {
                encode = typeStr;
            } else {
                NSString *argClassName = trim([typeStr stringByReplacingOccurrencesOfString:@"*" withString:@""]);
                if (NSClassFromString(argClassName) != NULL) {
                    encode = @"@";
                } else {
                    NSCAssert(NO, @"unreconized type %@", typeStr);
                    return nil;
                }
            }
        }
        [encodeStr appendString:encode];
    }
    return encodeStr;
}

static id getArgument(id valObj){
    if ([valObj isKindOfClass:[NSNumber class]] && strcmp([valObj objCType], "c") == 0 && ![valObj boolValue]) {
        return nil;
    }
    return valObj;
}

static NSString *trim(NSString *string)
{
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *extractStructName(NSString *typeEncodeString)
{
    NSArray *array = [typeEncodeString componentsSeparatedByString:@"="];
    NSString *typeString = array[0];
    int firstValidIndex = 0;
    for (int i = 0; i< typeString.length; i++) {
        char c = [typeString characterAtIndex:i];
        if (c == '{' || c=='_') {
            firstValidIndex++;
        }else {
            break;
        }
    }
    return [typeString substringFromIndex:firstValidIndex];
}
@end
