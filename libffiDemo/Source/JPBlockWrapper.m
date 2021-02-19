//
//  JPBlockWrapper.m
//  JSPatch
//
//  Created by bang on 1/19/17.
//  Copyright © 2017 bang. All rights reserved.
//

#import "JPBlockWrapper.h"
#import "ffi.h"
#import "JPMethodSignature.h"

enum {
    BLOCK_DEALLOCATING =      (0x0001),
    BLOCK_REFCOUNT_MASK =     (0xfffe),
    BLOCK_NEEDS_FREE =        (1 << 24),
    BLOCK_HAS_COPY_DISPOSE =  (1 << 25),
    BLOCK_HAS_CTOR =          (1 << 26),
    BLOCK_IS_GC =             (1 << 27),
    BLOCK_IS_GLOBAL =         (1 << 28),
    BLOCK_USE_STRET =         (1 << 29),
    BLOCK_HAS_SIGNATURE  =    (1 << 30)
};

struct JPSimulateBlock {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct JPSimulateBlockDescriptor *descriptor;
    void *wrapper;
};

struct JPSimulateBlockDescriptor {
    //Block_descriptor_1
    struct {
        unsigned long int reserved;
        unsigned long int size;
    };

    //Block_descriptor_2
    struct {
        // requires BLOCK_HAS_COPY_DISPOSE
        void (*copy)(void *dst, const void *src);
        void (*dispose)(const void *);
    };

    //Block_descriptor_3
    struct {
        // requires BLOCK_HAS_SIGNATURE
        const char *signature;
    };
};

void copy_helper(struct JPSimulateBlock *dst, struct JPSimulateBlock *src)
{
    // do not copy anything is this funcion! just retain if need.
    CFRetain(dst->wrapper);
}

void dispose_helper(struct JPSimulateBlock *src)
{
    CFRelease(src->wrapper);
}


@interface JPBlockWrapper ()
{
    ffi_cif *_cifPtr;
    ffi_type **_args;
    ffi_closure *_closure;
    BOOL _generatedPtr;
    void *_blockPtr;
    struct JPSimulateBlockDescriptor *_descriptor;
}

@property (nonatomic,strong) JPMethodSignature *signature;
@property (nonatomic,strong) JSValue *jsFunction;

@end

void JPBlockInterpreter(ffi_cif *cif, void *ret, void **args, void *userdata)
{
    JPBlockWrapper *blockObj = (__bridge JPBlockWrapper*)userdata;

    //根据签名中的参数类型，取出参数值，放入参数数组
    NSMutableArray *params = [[NSMutableArray alloc] init];
    for (int i = 1; i < blockObj.signature.argumentTypes.count; i ++) {
        id param;
        void *argumentPtr = args[i];
        const char *typeEncoding = [blockObj.signature.argumentTypes[i] UTF8String];
        switch (typeEncoding[0]) {
                
        #define JP_BLOCK_PARAM_CASE(_typeString, _type, _selector) \
            case _typeString: {                              \
                _type returnValue = *(_type *)argumentPtr;                     \
                param = [NSNumber _selector:returnValue];\
                break; \
            }
            JP_BLOCK_PARAM_CASE('c', char, numberWithChar)
            JP_BLOCK_PARAM_CASE('C', unsigned char, numberWithUnsignedChar)
            JP_BLOCK_PARAM_CASE('s', short, numberWithShort)
            JP_BLOCK_PARAM_CASE('S', unsigned short, numberWithUnsignedShort)
            JP_BLOCK_PARAM_CASE('i', int, numberWithInt)
            JP_BLOCK_PARAM_CASE('I', unsigned int, numberWithUnsignedInt)
            JP_BLOCK_PARAM_CASE('l', long, numberWithLong)
            JP_BLOCK_PARAM_CASE('L', unsigned long, numberWithUnsignedLong)
            JP_BLOCK_PARAM_CASE('q', long long, numberWithLongLong)
            JP_BLOCK_PARAM_CASE('Q', unsigned long long, numberWithUnsignedLongLong)
            JP_BLOCK_PARAM_CASE('f', float, numberWithFloat)
            JP_BLOCK_PARAM_CASE('d', double, numberWithDouble)
            JP_BLOCK_PARAM_CASE('B', BOOL, numberWithBool)
                
            case '@': {
                param = (__bridge id)(*(void**)argumentPtr);
                break;
            }
        }
//        [params addObject:[JPExtension formatOCToJS:param]];
        [param addObject:param];
    }
    //执行js方法
    JSValue *jsResult = [blockObj.jsFunction callWithArguments:params];

    //根据返回值类型处理返回值
    switch ([blockObj.signature.returnType UTF8String][0]) {
            
    #define JP_BLOCK_RET_CASE(_typeString, _type, _selector) \
        case _typeString: {                              \
            _type *retPtr = ret; \
            *retPtr = [((NSNumber *)[jsResult toObject]) _selector];   \
            break; \
        }
        
        JP_BLOCK_RET_CASE('c', char, charValue)
        JP_BLOCK_RET_CASE('C', unsigned char, unsignedCharValue)
        JP_BLOCK_RET_CASE('s', short, shortValue)
        JP_BLOCK_RET_CASE('S', unsigned short, unsignedShortValue)
        JP_BLOCK_RET_CASE('i', int, intValue)
        JP_BLOCK_RET_CASE('I', unsigned int, unsignedIntValue)
        JP_BLOCK_RET_CASE('l', long, longValue)
        JP_BLOCK_RET_CASE('L', unsigned long, unsignedLongValue)
        JP_BLOCK_RET_CASE('q', long long, longLongValue)
        JP_BLOCK_RET_CASE('Q', unsigned long long, unsignedLongLongValue)
        JP_BLOCK_RET_CASE('f', float, floatValue)
        JP_BLOCK_RET_CASE('d', double, doubleValue)
        JP_BLOCK_RET_CASE('B', BOOL, boolValue)
            
        case '@':
        case '#': {
//            id retObj = [JPExtension formatJSToOC:jsResult];
            id retObj = [jsResult toObject];
            void **retPtrPtr = ret;
            *retPtrPtr = (__bridge void *)retObj;
            break;
        }
        case '^': {
//            JPBoxing *box = [JPExtension formatJSToOC:jsResult];
            JPBoxing *box = [jsResult toObject];
            void *pointer = [box unboxPointer];
            void **retPtrPtr = ret;
            *retPtrPtr = pointer;
            break;
        }
    }
    
}

@implementation JPBlockWrapper

- (id)initWithTypeString:(NSString *)typeString callbackFunction:(JSValue *)jsFunction
{
    self = [super init];
    if(self) {
        _generatedPtr = NO;
        self.jsFunction = jsFunction;
        self.signature = [[JPMethodSignature alloc] initWithBlockTypeNames:typeString];
    }
    return self;
}

- (void *)blockPtr
{
    //已经生成过block指针了，就直接返回
    if (_generatedPtr) {
        return _blockPtr;
    }
    
    _generatedPtr = YES;
    //返回值类型
    ffi_type *returnType = [JPMethodSignature ffiTypeWithEncodingChar:[self.signature.returnType UTF8String]];
    
    NSUInteger argumentCount = self.signature.argumentTypes.count;
    
    _cifPtr = malloc(sizeof(ffi_cif));
    
    void *blockImp = NULL;
    //拼装参数类型数组
    _args = malloc(sizeof(ffi_type *) *argumentCount) ;
    
    for (int i = 0; i < argumentCount; i++){
        ffi_type* current_ffi_type = [JPMethodSignature ffiTypeWithEncodingChar:[self.signature.argumentTypes[i] UTF8String]];
        _args[i] = current_ffi_type;
    }
    //申请闭包内存空间
    _closure = ffi_closure_alloc(sizeof(ffi_closure), (void **)&blockImp);
    //校验
    if(ffi_prep_cif(_cifPtr, FFI_DEFAULT_ABI, (unsigned int)argumentCount, returnType, _args) == FFI_OK) {
        //生成block函数指针
        if (ffi_prep_closure_loc(_closure, _cifPtr, JPBlockInterpreter, (__bridge void *)self, blockImp) != FFI_OK) {
            NSAssert(NO, @"generate block error");
        }
    }
    //仿造一个block对象
    struct JPSimulateBlockDescriptor descriptor = {
        0,
        sizeof(struct JPSimulateBlock),
        (void (*)(void *dst, const void *src))copy_helper,
        (void (*)(const void *src))dispose_helper,
        [self.signature.types cStringUsingEncoding:NSASCIIStringEncoding]
    };
    
    _descriptor = malloc(sizeof(struct JPSimulateBlockDescriptor));
    memcpy(_descriptor, &descriptor, sizeof(struct JPSimulateBlockDescriptor));

    struct JPSimulateBlock simulateBlock = {
        &_NSConcreteStackBlock,
        (BLOCK_HAS_COPY_DISPOSE | BLOCK_HAS_SIGNATURE),
        0,
        blockImp,
        _descriptor,
        (__bridge void*)self
    };

    _blockPtr = Block_copy(&simulateBlock);
    return _blockPtr;
}

- (void)dealloc
{
    ffi_closure_free(_closure);
    free(_args);
    free(_cifPtr);
    free(_descriptor);
    return;
}

#pragma mark - genCallbackBlock

//static id genCallbackBlock(JSValue *jsVal)
//{
//    //jsVal是字典、@"args"是参数类型字符串 @"cb"是函数
//    //生成一个block，替换函数指针、方法签名
//    void (^block)(void) = ^(void){};
//    uint8_t *p = (uint8_t *)((__bridge void *)block);
//    p += sizeof(void *) + sizeof(int32_t) *2;
//    void(**invoke)(void) = (void (**)(void))p;//指针偏移拿到函数指针
//
//    p += sizeof(void *) + sizeof(uintptr_t) * 2;
//    const char **signature = (const char **)p;//指针偏移拿到函数签名
//
//    //在字典里预设类型对应类型签名
//    static NSMutableDictionary *typeSignatureDict;
//    if (!typeSignatureDict) {
//        typeSignatureDict  = [NSMutableDictionary new];
//        #define JP_DEFINE_TYPE_SIGNATURE(_type) \
//        [typeSignatureDict setObject:@[[NSString stringWithUTF8String:@encode(_type)], @(sizeof(_type))] forKey:@#_type];\
//
//        JP_DEFINE_TYPE_SIGNATURE(id);
//        JP_DEFINE_TYPE_SIGNATURE(BOOL);
//        JP_DEFINE_TYPE_SIGNATURE(int);
//        JP_DEFINE_TYPE_SIGNATURE(void);
//        JP_DEFINE_TYPE_SIGNATURE(char);
//        JP_DEFINE_TYPE_SIGNATURE(short);
//        JP_DEFINE_TYPE_SIGNATURE(unsigned short);
//        JP_DEFINE_TYPE_SIGNATURE(unsigned int);
//        JP_DEFINE_TYPE_SIGNATURE(long);
//        JP_DEFINE_TYPE_SIGNATURE(unsigned long);
//        JP_DEFINE_TYPE_SIGNATURE(long long);
//        JP_DEFINE_TYPE_SIGNATURE(unsigned long long);
//        JP_DEFINE_TYPE_SIGNATURE(float);
//        JP_DEFINE_TYPE_SIGNATURE(double);
//        JP_DEFINE_TYPE_SIGNATURE(bool);
//        JP_DEFINE_TYPE_SIGNATURE(size_t);
//        JP_DEFINE_TYPE_SIGNATURE(CGFloat);
//        JP_DEFINE_TYPE_SIGNATURE(CGSize);
//        JP_DEFINE_TYPE_SIGNATURE(CGRect);
//        JP_DEFINE_TYPE_SIGNATURE(CGPoint);
//        JP_DEFINE_TYPE_SIGNATURE(CGVector);
//        JP_DEFINE_TYPE_SIGNATURE(NSRange);
//        JP_DEFINE_TYPE_SIGNATURE(NSInteger);
//        JP_DEFINE_TYPE_SIGNATURE(Class);
//        JP_DEFINE_TYPE_SIGNATURE(SEL);
//        JP_DEFINE_TYPE_SIGNATURE(void*);
//        JP_DEFINE_TYPE_SIGNATURE(void *);
//    }
//
//    NSString *types = [jsVal[@"args"] toString];
//    NSArray *lt = [types componentsSeparatedByString:@","];
//
//    NSString *funcSignature = @"@?0";
//
//    NSInteger size = sizeof(void *);
//    for (NSInteger i = 1; i < lt.count;) {
//        NSString *t = trim(lt[i]);
//        NSString *tpe = typeSignatureDict[typeSignatureDict[t] ? t : @"id"][0];
//        if (i == 0) {
//            funcSignature  =[[NSString stringWithFormat:@"%@%@",tpe, [@(size) stringValue]] stringByAppendingString:funcSignature];
//            break;
//        }
//
//        funcSignature = [funcSignature stringByAppendingString:[NSString stringWithFormat:@"%@%@", tpe, [@(size) stringValue]]];
//        size += [typeSignatureDict[typeSignatureDict[t] ? t : @"id"][1] integerValue];
//
//        i = (i != lt.count - 1) ? i + 1 : 0;
//    }
//
//    IMP msgForwardIMP = _objc_msgForward;
//#if !defined(__arm64__)
//    if ([funcSignature UTF8String][0] == '{') {
//        //In some cases that returns struct, we should use the '_stret' API:
//        //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
//        //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
//        NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:[funcSignature UTF8String]];
//        if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
//            msgForwardIMP = (IMP)_objc_msgForward_stret;
//        }
//    }
//#endif
//    *invoke = (void *)msgForwardIMP;//函数指针替换成消息转发
//
//    const char *fs = [funcSignature UTF8String];
//    char *s = malloc(strlen(fs));
//    strcpy(s, fs);
//    *signature = s;//替换方法签名
//
//    objc_setAssociatedObject(block, "_JSValue", jsVal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);//保存jsVal
//
//    static dispatch_once_t onceToken;
//    dispatch_once(&onceToken, ^{
//        Class cls = NSClassFromString(@"NSBlock");//替换block的两个消息转发方法
//#define JP_HOOK_METHOD(selector, func) {Method method = class_getInstanceMethod([NSObject class], selector); \
//BOOL success = class_addMethod(cls, selector, (IMP)func, method_getTypeEncoding(method)); \
//if (!success) { class_replaceMethod(cls, selector, (IMP)func, method_getTypeEncoding(method));}}
//
//        JP_HOOK_METHOD(@selector(methodSignatureForSelector:), block_methodSignatureForSelector);
//        JP_HOOK_METHOD(@selector(forwardInvocation:), JPForwardInvocation);
//    });
//
//    return block;
//}




//static void JPForwardInvocation(__unsafe_unretained id assignSlf, SEL selector, NSInvocation *invocation)
//{
//
//#ifdef DEBUG
//    _JSLastCallStack = [NSThread callStackSymbols];
//#endif
//    BOOL deallocFlag = NO;
//    id slf = assignSlf;
//    BOOL isBlock = [[assignSlf class] isSubclassOfClass : NSClassFromString(@"NSBlock")];
//
//    NSMethodSignature *methodSignature = [invocation methodSignature];
//    NSInteger numberOfArguments = [methodSignature numberOfArguments];
//    NSString *selectorName = isBlock ? @"" : NSStringFromSelector(invocation.selector);
//    NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
//    JSValue *jsFunc = isBlock ? objc_getAssociatedObject(assignSlf, "_JSValue")[@"cb"] : getJSFunctionInObjectHierachy(slf, JPSelectorName);
//    if (!jsFunc) {
//        JPExecuteORIGForwardInvocation(slf, selector, invocation);
//        return;
//    }
//    //组装参数列表
//    NSMutableArray *argList = [[NSMutableArray alloc] init];
//    if (!isBlock) {
//        if ([slf class] == slf) {
//            [argList addObject:[JSValue valueWithObject:@{@"__clsName": NSStringFromClass([slf class])} inContext:_context]];
//        } else if ([selectorName isEqualToString:@"dealloc"]) {
//            [argList addObject:[JPBoxing boxAssignObj:slf]];
//            deallocFlag = YES;
//        } else {
//            [argList addObject:[JPBoxing boxWeakObj:slf]];
//        }
//    }
//
//    for (NSUInteger i = isBlock ? 1 : 2; i < numberOfArguments; i++) {
//        const char *argumentType = [methodSignature getArgumentTypeAtIndex:i];
//        switch(argumentType[0] == 'r' ? argumentType[1] : argumentType[0]) {
//
//            #define JP_FWD_ARG_CASE(_typeChar, _type) \
//            case _typeChar: {   \
//                _type arg;  \
//                [invocation getArgument:&arg atIndex:i];    \
//                [argList addObject:@(arg)]; \
//                break;  \
//            }
//            JP_FWD_ARG_CASE('c', char)
//            JP_FWD_ARG_CASE('C', unsigned char)
//            JP_FWD_ARG_CASE('s', short)
//            JP_FWD_ARG_CASE('S', unsigned short)
//            JP_FWD_ARG_CASE('i', int)
//            JP_FWD_ARG_CASE('I', unsigned int)
//            JP_FWD_ARG_CASE('l', long)
//            JP_FWD_ARG_CASE('L', unsigned long)
//            JP_FWD_ARG_CASE('q', long long)
//            JP_FWD_ARG_CASE('Q', unsigned long long)
//            JP_FWD_ARG_CASE('f', float)
//            JP_FWD_ARG_CASE('d', double)
//            JP_FWD_ARG_CASE('B', BOOL)
//            case '@': {
//                __unsafe_unretained id arg;
//                [invocation getArgument:&arg atIndex:i];
//                if ([arg isKindOfClass:NSClassFromString(@"NSBlock")]) {
//                    [argList addObject:(arg ? [arg copy]: _nilObj)];
//                } else {
//                    [argList addObject:(arg ? arg: _nilObj)];
//                }
//                break;
//            }
//            case '{': {
//                NSString *typeString = extractStructName([NSString stringWithUTF8String:argumentType]);
//                #define JP_FWD_ARG_STRUCT(_type, _transFunc) \
//                if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
//                    _type arg; \
//                    [invocation getArgument:&arg atIndex:i];    \
//                    [argList addObject:[JSValue _transFunc:arg inContext:_context]];  \
//                    break; \
//                }
//                JP_FWD_ARG_STRUCT(CGRect, valueWithRect)
//                JP_FWD_ARG_STRUCT(CGPoint, valueWithPoint)
//                JP_FWD_ARG_STRUCT(CGSize, valueWithSize)
//                JP_FWD_ARG_STRUCT(NSRange, valueWithRange)
//
//                @synchronized (_context) {
//                    NSDictionary *structDefine = _registeredStruct[typeString];
//                    if (structDefine) {
//                        size_t size = sizeOfStructTypes(structDefine[@"types"]);
//                        if (size) {
//                            void *ret = malloc(size);
//                            [invocation getArgument:ret atIndex:i];
//                            NSDictionary *dict = getDictOfStruct(ret, structDefine);
//                            [argList addObject:[JSValue valueWithObject:dict inContext:_context]];
//                            free(ret);
//                            break;
//                        }
//                    }
//                }
//
//                break;
//            }
//            case ':': {
//                SEL selector;
//                [invocation getArgument:&selector atIndex:i];
//                NSString *selectorName = NSStringFromSelector(selector);
//                [argList addObject:(selectorName ? selectorName: _nilObj)];
//                break;
//            }
//            case '^':
//            case '*': {
//                void *arg;
//                [invocation getArgument:&arg atIndex:i];
//                [argList addObject:[JPBoxing boxPointer:arg]];
//                break;
//            }
//            case '#': {
//                Class arg;
//                [invocation getArgument:&arg atIndex:i];
//                [argList addObject:[JPBoxing boxClass:arg]];
//                break;
//            }
//            default: {
//                NSLog(@"error type %s", argumentType);
//                break;
//            }
//        }
//    }
//
//    if (_currInvokeSuperClsName[selectorName]) {
//        Class cls = NSClassFromString(_currInvokeSuperClsName[selectorName]);
//        NSString *tmpSelectorName = [[selectorName stringByReplacingOccurrencesOfString:@"_JPSUPER_" withString:@"_JP"] stringByReplacingOccurrencesOfString:@"SUPER_" withString:@"_JP"];
//        if (!_JSOverideMethods[cls][tmpSelectorName]) {//这个父类方法没有被hook，就执行原方法
//            NSString *ORIGSelectorName = [selectorName stringByReplacingOccurrencesOfString:@"SUPER_" withString:@"ORIG"];
//            [argList removeObjectAtIndex:0];
//            id retObj = callSelector(_currInvokeSuperClsName[selectorName], ORIGSelectorName, [JSValue valueWithObject:argList inContext:_context], [JSValue valueWithObject:@{@"__obj": slf, @"__realClsName": @""} inContext:_context], NO);
//            id __autoreleasing ret = formatJSToOC([JSValue valueWithObject:retObj inContext:_context]);
//            [invocation setReturnValue:&ret];
//            return;
//        }
//    }
//
//    NSArray *params = _formatOCToJSList(argList);
//    char returnType[255];
//    strcpy(returnType, [methodSignature methodReturnType]);
//
//    // Restore the return type
//    if (strcmp(returnType, @encode(JPDouble)) == 0) {
//        strcpy(returnType, @encode(double));
//    }
//    if (strcmp(returnType, @encode(JPFloat)) == 0) {
//        strcpy(returnType, @encode(float));
//    }
//    //根据返回值的不同，做不同处理
//    switch (returnType[0] == 'r' ? returnType[1] : returnType[0]) {
//        #define JP_FWD_RET_CALL_JS \
//            JSValue *jsval; \
//            [_JSMethodForwardCallLock lock];   \
//            jsval = [jsFunc callWithArguments:params]; \
//            [_JSMethodForwardCallLock unlock]; \
//            while (![jsval isNull] && ![jsval isUndefined] && [jsval hasProperty:@"__isPerformInOC"]) { \
//                NSArray *args = nil;  \
//                JSValue *cb = jsval[@"cb"]; \
//                if ([jsval hasProperty:@"sel"]) {   \
//                    id callRet = callSelector(![jsval[@"clsName"] isUndefined] ? [jsval[@"clsName"] toString] : nil, [jsval[@"sel"] toString], jsval[@"args"], ![jsval[@"obj"] isUndefined] ? jsval[@"obj"] : nil, NO);  \
//                    args = @[[_context[@"_formatOCToJS"] callWithArguments:callRet ? @[callRet] : _formatOCToJSList(@[_nilObj])]];  \
//                }   \
//                [_JSMethodForwardCallLock lock];    \
//                jsval = [cb callWithArguments:args];  \
//                [_JSMethodForwardCallLock unlock];  \
//            }
//
//        #define JP_FWD_RET_CASE_RET(_typeChar, _type, _retCode)   \
//            case _typeChar : { \
//                JP_FWD_RET_CALL_JS \
//                _retCode \
//                [invocation setReturnValue:&ret];\
//                break;  \
//            }
//
//        #define JP_FWD_RET_CASE(_typeChar, _type, _typeSelector)   \
//            JP_FWD_RET_CASE_RET(_typeChar, _type, _type ret = [[jsval toObject] _typeSelector];)   \
//
//        #define JP_FWD_RET_CODE_ID \
//            id __autoreleasing ret = formatJSToOC(jsval); \
//            if (ret == _nilObj ||   \
//                ([ret isKindOfClass:[NSNumber class]] && strcmp([ret objCType], "c") == 0 && ![ret boolValue])) ret = nil;  \
//
//        #define JP_FWD_RET_CODE_POINTER    \
//            void *ret; \
//            id obj = formatJSToOC(jsval); \
//            if ([obj isKindOfClass:[JPBoxing class]]) { \
//                ret = [((JPBoxing *)obj) unboxPointer]; \
//            }
//
//        #define JP_FWD_RET_CODE_CLASS    \
//            Class ret;   \
//            ret = formatJSToOC(jsval);
//
//
//        #define JP_FWD_RET_CODE_SEL    \
//            SEL ret;   \
//            id obj = formatJSToOC(jsval); \
//            if ([obj isKindOfClass:[NSString class]]) { \
//                ret = NSSelectorFromString(obj); \
//            }
//
//        JP_FWD_RET_CASE_RET('@', id, JP_FWD_RET_CODE_ID)
//        JP_FWD_RET_CASE_RET('^', void*, JP_FWD_RET_CODE_POINTER)
//        JP_FWD_RET_CASE_RET('*', void*, JP_FWD_RET_CODE_POINTER)
//        JP_FWD_RET_CASE_RET('#', Class, JP_FWD_RET_CODE_CLASS)
//        JP_FWD_RET_CASE_RET(':', SEL, JP_FWD_RET_CODE_SEL)
//
//        JP_FWD_RET_CASE('c', char, charValue)
//        JP_FWD_RET_CASE('C', unsigned char, unsignedCharValue)
//        JP_FWD_RET_CASE('s', short, shortValue)
//        JP_FWD_RET_CASE('S', unsigned short, unsignedShortValue)
//        JP_FWD_RET_CASE('i', int, intValue)
//        JP_FWD_RET_CASE('I', unsigned int, unsignedIntValue)
//        JP_FWD_RET_CASE('l', long, longValue)
//        JP_FWD_RET_CASE('L', unsigned long, unsignedLongValue)
//        JP_FWD_RET_CASE('q', long long, longLongValue)
//        JP_FWD_RET_CASE('Q', unsigned long long, unsignedLongLongValue)
//        JP_FWD_RET_CASE('f', float, floatValue)
//        JP_FWD_RET_CASE('d', double, doubleValue)
//        JP_FWD_RET_CASE('B', BOOL, boolValue)
//
//        case 'v': {
//            JP_FWD_RET_CALL_JS
//            break;
//        }
//
//        case '{': {
//            NSString *typeString = extractStructName([NSString stringWithUTF8String:returnType]);
//            #define JP_FWD_RET_STRUCT(_type, _funcSuffix) \
//            if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
//                JP_FWD_RET_CALL_JS \
//                _type ret = [jsval _funcSuffix]; \
//                [invocation setReturnValue:&ret];\
//                break;  \
//            }
//            JP_FWD_RET_STRUCT(CGRect, toRect)
//            JP_FWD_RET_STRUCT(CGPoint, toPoint)
//            JP_FWD_RET_STRUCT(CGSize, toSize)
//            JP_FWD_RET_STRUCT(NSRange, toRange)
//
//            @synchronized (_context) {
//                NSDictionary *structDefine = _registeredStruct[typeString];
//                if (structDefine) {
//                    size_t size = sizeOfStructTypes(structDefine[@"types"]);
//                    JP_FWD_RET_CALL_JS
//                    void *ret = malloc(size);
//                    NSDictionary *dict = formatJSToOC(jsval);
//                    getStructDataWithDict(ret, dict, structDefine);
//                    [invocation setReturnValue:ret];
//                    free(ret);
//                }
//            }
//            break;
//        }
//        default: {
//            break;
//        }
//    }
//
//    if (_pointersToRelease) {
//        for (NSValue *val in _pointersToRelease) {
//            void *pointer = NULL;
//            [val getValue:&pointer];
//            CFRelease(pointer);
//        }
//        _pointersToRelease = nil;
//    }
//
//    if (deallocFlag) {//如果是dealloc方法，除了执行hook的方法，还要执行原dealloc，否则不释放内存了
//        slf = nil;
//        Class instClass = object_getClass(assignSlf);
//        Method deallocMethod = class_getInstanceMethod(instClass, NSSelectorFromString(@"ORIGdealloc"));
//        void (*originalDealloc)(__unsafe_unretained id, SEL) = (__typeof__(originalDealloc))method_getImplementation(deallocMethod);
//        originalDealloc(assignSlf, NSSelectorFromString(@"dealloc"));
//    }
//}
@end
