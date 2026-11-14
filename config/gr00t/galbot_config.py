from gr00t.configs.data.embodiment_configs import register_modality_config
from gr00t.data.embodiment_tags import EmbodimentTag
from gr00t.data.types import (ModalityConfig, ActionConfig,
                              ActionRepresentation as Rep, ActionType as T, ActionFormat as F)

galbot_config = {
    "video":  ModalityConfig(delta_indices=[0], modality_keys=["head", "left_wrist", "right_wrist"]),
    "state":  ModalityConfig(delta_indices=[0], modality_keys=["left_eef", "right_eef", "left_gripper", "right_gripper"]),
    "action": ModalityConfig(
        delta_indices=list(range(40)),
        modality_keys=["left_eef", "right_eef", "left_gripper", "right_gripper", "base_wheels"],
        action_configs=[
            ActionConfig(rep=Rep.RELATIVE, type=T.EEF,     format=F.XYZ_ROT6D, state_key="left_eef"),
            ActionConfig(rep=Rep.RELATIVE, type=T.EEF,     format=F.XYZ_ROT6D, state_key="right_eef"),
            ActionConfig(rep=Rep.ABSOLUTE, type=T.NON_EEF, format=F.DEFAULT),
            ActionConfig(rep=Rep.ABSOLUTE, type=T.NON_EEF, format=F.DEFAULT),
            ActionConfig(rep=Rep.ABSOLUTE, type=T.NON_EEF, format=F.DEFAULT),
        ],
    ),
    "language": ModalityConfig(delta_indices=[0], modality_keys=["annotation.human.task_description"]),
}
register_modality_config(galbot_config, embodiment_tag=EmbodimentTag.NEW_EMBODIMENT)
