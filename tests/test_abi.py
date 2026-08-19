from aibrain_rkllm.abi import RKLLMParam, bind_runtime, default_parameters


class Function:
    def __init__(self, result=None):
        self.argtypes = None
        self.restype = None
        self.result = result

    def __call__(self):
        return self.result


class FakeLibrary:
    def __init__(self):
        self.rkllm_createDefaultParam = Function(RKLLMParam())
        self.rkllm_destroy = Function()


def test_binds_known_runtime_symbols():
    library = FakeLibrary()
    bind_runtime(library)
    assert library.rkllm_createDefaultParam.argtypes == []
    assert library.rkllm_createDefaultParam.restype is RKLLMParam
    assert library.rkllm_destroy.argtypes is not None


def test_reads_default_parameters_without_model_initialization():
    assert isinstance(default_parameters(FakeLibrary()), RKLLMParam)
