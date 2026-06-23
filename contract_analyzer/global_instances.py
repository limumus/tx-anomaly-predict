_initialized = False
skip_rag_manager = None
exclusion_middleware = None

def init_global_instances():
    global _initialized, skip_rag_manager, exclusion_middleware
    
    if _initialized:
        return
    
    try:
        from utils.debug_utils import StateManager
        from core.middleware import IntelligentExclusionSystem
        
        skip_rag_manager = StateManager()
        exclusion_middleware = IntelligentExclusionSystem("exclusion_middleware_fixed")
        _initialized = True
        
    except ImportError as e:
        raise
    except Exception as e:
        raise

def get_skip_rag_manager():
    global skip_rag_manager
    if skip_rag_manager is None:
        init_global_instances()
    return skip_rag_manager

def get_exclusion_middleware():
    global exclusion_middleware
    if exclusion_middleware is None:
        init_global_instances()
    return exclusion_middleware

__all__ = [
    'skip_rag_manager',
    'exclusion_middleware',
    'init_global_instances',
    'get_skip_rag_manager',
    'get_exclusion_middleware'
]