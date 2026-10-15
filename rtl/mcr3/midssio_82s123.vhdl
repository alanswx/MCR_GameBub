library ieee;
use ieee.std_logic_1164.all,ieee.numeric_std.all;

entity midssio_82s123 is
port (
 prom_addr : in std_logic_vector(4 downto 0);
 prom_data : in std_logic_vector(7 downto 0);
 prom_wr   : in std_logic;
	clk  : in  std_logic;
	addr : in  std_logic_vector(4 downto 0);
	data : out std_logic_vector(7 downto 0)
);
end entity;

architecture prom of midssio_82s123 is
	type rom is array(0 to  31) of std_logic_vector(7 downto 0);
	signal rom_data: rom;
begin
process(clk)
begin
	if rising_edge(clk) then
		if prom_wr = '1' then
			rom_data(to_integer(unsigned(prom_addr))) <= prom_data;
		end if;
		data <= rom_data(to_integer(unsigned(addr)));
	end if;
end process;
end architecture;
